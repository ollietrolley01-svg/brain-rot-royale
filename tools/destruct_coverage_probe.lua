-- Destruction coverage audit (Oliver 2026-09-24: "make sure everything is destructible"), for
-- tools/runtest.ps1 -Probe. Build the place first (python build_place.py .), then:
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/destruct_coverage_probe.lua -WaitSeconds 600 [-PlaceFile <rbxlx>]
--
-- Builds real maps the way a match does (MapGenerator.Build; on the last one ModeTeams.Setup for a
-- Team Deathmatch too, so the team battleground and both team bases are in it), then asks
-- DestructibleService.Explain about EVERY anchored part in a match root that collides or can be hit
-- (CanCollide or CanQuery). Each one is exactly one of:
--
--   breakable     a pool that would take damage (its pool is resolved, span-checked and sized, exactly
--                 as the first hit would)
--   excluded      kept whole by design, with the reason (a road, a bridge deck, a footing, a ground
--                 slab, an objective...): DestructibleService.Explain names the rule that refused it
--   UNEXPLAINED   neither: a hole in the coverage. Target 0.
--
-- It prints totals per map, then every UNEXPLAINED group (by the Models it sits in, digits stripped,
-- and its name and material) with a count and an example path, then the excluded groups by reason,
-- so the exclusions can be read and argued with. It also lists what else stands directly under
-- workspace (outside the match roots), so geometry parented somewhere new shows up here the day it
-- lands.
--
-- Floating (the second half of "everything breaks"): on the last map it breaks a sample of pools of
-- every kind through the real DestructibleService and then looks for anything the break left in the
-- air -- a solid part or trim piece that touched a broken part and now touches nothing solid and has
-- nothing under it. Want 0. (Edit mode has no physics, so this is geometry, not falling.)
--
-- Re-runnable on a merged tree: nothing here names a module's parts. New geometry is audited by the
-- same rules the service applies to it.

local MAPS = {
	{ id = "SahurSprings", seed = 11 },
	{ id = "RotRidge", seed = 101, teams = true },
}
local SAMPLE_BREAKS = 260
local TOP_GROUPS = 120

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function out(fmt, ...)
	print("[AUDIT destruct] " .. string.format(fmt, ...))
end

local modules = ServerScriptService:WaitForChild("Modules")
local DS = require(modules:WaitForChild("DestructibleService"))
local MapGenerator = require(modules:WaitForChild("MapGenerator"))

local function strip(name)
	local s = name:gsub("[_%s%-]*%d+$", "")
	return s
end

-- The Models a part sits in under its root (digits stripped), at most three deep: the building
-- module's own grouping (Town/House/..., Props/..., TeamBase/...).
local function labelOf(part, root)
	local chain = {}
	local node = part.Parent
	while node and node ~= root and node ~= workspace do
		table.insert(chain, 1, strip(node.Name))
		node = node.Parent
	end
	while #chain > 3 do
		table.remove(chain, #chain)
	end
	return (root and root.Name or "?") .. "/" .. table.concat(chain, "/")
end

-- The pre-opt-out service had no Explain: a crude stand-in so the audit can take a baseline.
local function fallbackExplain(part)
	if not part.Anchored then
		return "excluded", "unanchored"
	end
	if DS.FromPart(part) then
		return "breakable", "legacy"
	end
	local node = part
	while node and node ~= workspace do
		if DS.Never and DS.Never[node.Name] then
			return "excluded", "never:" .. node.Name
		end
		if node:GetAttribute("Destructible") == false then
			return "excluded", "tagged false"
		end
		node = node.Parent
	end
	return "unexplained", "legacy: no tag, no HEALTH name"
end

local explain = DS.Explain or fallbackExplain
local roots = DS.Roots or { Map = true }

local function audit(label)
	local counts = { breakable = 0, excluded = 0, unexplained = 0, trim = 0 }
	local how = {}
	local groups, reasons = {}, {}
	local pools = {}
	for name in pairs(roots) do
		local root = workspace:FindFirstChild(name)
		for _, part in ipairs(root and root:GetDescendants() or {}) do
			if part:IsA("BasePart") and part.Anchored then
				if not (part.CanCollide or part.CanQuery) then
					counts.trim += 1
				else
					local ok, status, reason, key = pcall(explain, part)
					if not ok then
						status, reason = "unexplained", "Explain error: " .. tostring(status)
					end
					counts[status] = (counts[status] or 0) + 1
					if status == "unexplained" then
						local g = labelOf(part, root) .. " :: " .. part.Name .. " (" .. part.Material.Name .. ")"
						local entry = groups[g]
						if not entry then
							entry = { n = 0, example = part:GetFullName(), size = part.Size, why = reason }
							groups[g] = entry
						end
						entry.n += 1
					elseif status == "excluded" then
						local r = reasons[reason]
						if not r then
							r = { n = 0, labels = {} }
							reasons[reason] = r
						end
						r.n += 1
						local l = labelOf(part, root) .. "::" .. part.Name
						r.labels[l] = (r.labels[l] or 0) + 1
					elseif status == "breakable" then
						how[reason] = (how[reason] or 0) + 1
						if key ~= nil and not pools[key] then
							pools[key] = part
						end
					end
				end
			end
		end
	end
	local poolCount = 0
	for _ in pairs(pools) do
		poolCount += 1
	end
	out("%s: %d solid/queryable anchored parts: %d breakable (%d pools), %d excluded by design, %d UNEXPLAINED; %d trim (no collide, no query)",
		label, counts.breakable + counts.excluded + counts.unexplained, counts.breakable, poolCount, counts.excluded, counts.unexplained, counts.trim)
	local hows = {}
	for reason, n in pairs(how) do
		table.insert(hows, reason .. " " .. n)
	end
	table.sort(hows)
	out("  breakable by: %s", table.concat(hows, ", "))
	local list = {}
	for g, entry in pairs(groups) do
		table.insert(list, { g = g, e = entry })
	end
	table.sort(list, function(a, b)
		return a.e.n > b.e.n
	end)
	for index, item in ipairs(list) do
		if index > TOP_GROUPS then
			out("  ... %d more unexplained groups", #list - TOP_GROUPS)
			break
		end
		out("  UNEXPLAINED %4d  %s  [%s]  e.g. %s %s", item.e.n, item.g, tostring(item.e.why), item.e.example,
			string.format("%.1fx%.1fx%.1f", item.e.size.X, item.e.size.Y, item.e.size.Z))
	end
	local rlist = {}
	for reason, r in pairs(reasons) do
		table.insert(rlist, { reason = reason, r = r })
	end
	table.sort(rlist, function(a, b)
		return a.r.n > b.r.n
	end)
	for _, item in ipairs(rlist) do
		local labels = {}
		for l, n in pairs(item.r.labels) do
			table.insert(labels, { l = l, n = n })
		end
		table.sort(labels, function(a, b)
			return a.n > b.n
		end)
		local shown = {}
		for index = 1, math.min(24, #labels) do
			table.insert(shown, labels[index].l .. " x" .. labels[index].n)
		end
		out("  excluded %5d  %-28s %s%s", item.r.n, item.reason, table.concat(shown, ", "), #labels > 24 and (", +" .. (#labels - 24) .. " more") or "")
		-- Only four things may be kept whole (Oliver 2026-09-24): spawns, the lobby, the storm, the
		-- map's edges.
		if DS.KeptReasons and not DS.KeptReasons[item.reason] then
			out("  PROBLEM kept whole for a reason that is not one of the four: %s (%d parts)", item.reason, item.r.n)
		end
	end
	local reasonsSeen = {}
	for _, item in ipairs(rlist) do
		table.insert(reasonsSeen, item.reason)
	end
	out("  kept-whole reasons in this map: %s (allowed: spawn, lobby, storm, map edge)", #reasonsSeen > 0 and table.concat(reasonsSeen, ", ") or "none")
	return counts, pools
end

-- Whatever else stands straight under workspace with anchored solid parts in it.
local function otherRoots()
	for _, child in ipairs(workspace:GetChildren()) do
		if not roots[child.Name] and child ~= workspace.Terrain and not child:IsA("Camera") then
			local solid = 0
			for _, d in ipairs(child:GetDescendants()) do
				if d:IsA("BasePart") and d.Anchored and (d.CanCollide or d.CanQuery) then
					solid += 1
				end
			end
			if child:IsA("BasePart") and child.Anchored and (child.CanCollide or child.CanQuery) then
				solid += 1
			end
			if solid > 0 then
				local why = DS.OutsideRootReason and DS.OutsideRootReason(child) or "outside the match roots"
				out("  outside the roots: workspace.%s (%s), %d solid anchored parts: %s", child.Name, child.ClassName, solid, why)
			end
		end
	end
end

-- Breaks a sample of pools (a spread of every kind: every Nth in path order) in batches, lets the
-- support pass run, and measures what the breaks left in the air. Edit mode has no physics, so a
-- chunk the pass cut loose is unanchored where it stood: that is "dropped" (it falls in a live
-- game), not floating. Floating is what is still ANCHORED with nothing holding it: a solid part the
-- service's own HeldUp says nothing joins to the ground, or a piece of dressing that touched a
-- broken part and now touches nothing solid and has no ground under it.
local function floatingAfterBreaks(pools)
	local keys = {}
	for key, part in pairs(pools) do
		table.insert(keys, { key = key, part = part })
	end
	table.sort(keys, function(a, b)
		return a.part:GetFullName() < b.part:GetFullName()
	end)
	local step = math.max(1, math.floor(#keys / SAMPLE_BREAKS))
	local rootList = {}
	for name in pairs(roots) do
		local root = workspace:FindFirstChild(name)
		if root then
			table.insert(rootList, root)
		end
	end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = rootList
	local watch, watched = {}, {}
	local broken = 0
	local batch = 0
	for index = 1, #keys, step do
		local part = keys[index].part
		if part.Parent and part.Anchored then
			-- Everything touching it (solid) and its dressing, before it goes.
			for _, other in ipairs(workspace:GetPartBoundsInBox(part.CFrame, part.Size + Vector3.new(1, 1, 1), params)) do
				if other ~= part and not watched[other] then
					watched[other] = true
					table.insert(watch, { part = other, after = part.Name })
				end
			end
			for _, other in ipairs(DS.Gather and DS.Gather({ part }) or {}) do
				if other ~= part and not watched[other] then
					watched[other] = true
					table.insert(watch, { part = other, after = part.Name })
				end
			end
			DS.Damage(part, 1e7, nil, part.Position + Vector3.new(0, 5, -20))
			broken += 1
			batch += 1
			if batch >= 20 then
				batch = 0
				for _ = 1, 4 do
					task.wait()
				end
			end
		end
	end
	for _ = 1, 30 do
		task.wait()
	end
	local examined, floating, dropped, gone = 0, 0, 0, 0
	local examples = {}
	for _, item in ipairs(watch) do
		local other = item.part
		if not other.Parent then
			gone += 1
		elseif not other.Anchored then
			dropped += 1
		elseif other.Transparency < 1 then
			examined += 1
			local held
			if other.CanCollide and other.Name ~= DS.GlassName then
				held = DS.HeldUp(other)
			else
				-- Dressing or glass: touching something solid that is still there, or on the ground.
				held = false
				for _, t in ipairs(workspace:GetPartBoundsInBox(other.CFrame, other.Size + Vector3.new(0.3, 0.3, 0.3), params)) do
					if t ~= other and t.CanCollide and t.Anchored and t.Parent then
						held = true
						break
					end
				end
				held = held or (DS.OnTerrain and DS.OnTerrain(other))
			end
			if not held then
				floating += 1
				if #examples < 30 then
					table.insert(examples, other:GetFullName() .. " (after " .. item.after .. ")")
				end
			end
		end
	end
	out("floating: broke %d sampled pools; %d neighbours and dressing watched: %d broke with them, %d dropped (fall in a live game), %d still standing; %d LEFT IN THE AIR",
		broken, #watch, gone, dropped, examined, floating)
	for _, e in ipairs(examples) do
		out("  FLOATING %s", e)
	end
	local s = DS.SupportStats or {}
	out("support pass: %s passes, %s checks, %s chunks cut loose, %s toppled, worst pass %.1f ms", tostring(s.passes), tostring(s.checks),
		tostring(s.fell), tostring(s.toppled), (s.worst or 0) * 1000)
	local c = DS.Collapse and DS.Collapse.Stats
	if c then
		out("collapse: %d dropped, %d toppled, %d crumbled past the budget, peak %d falling at once", c.dropped, c.toppled, c.crumbled, c.peak)
	end
	-- Rubble: nothing in edit mode settles (no physics), but count what was already marked.
	local rubble = 0
	for _, root in ipairs(rootList) do
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("BasePart") and d:GetAttribute("Rubble") then
				rubble += 1
			end
		end
	end
	out("rubble parts: %d", rubble)
end

-- Rule (b): every breakable slab lying on the ground has the ground (or a footing) right under it,
-- and every slab with nothing under it at all is kept whole.
local function groundSlabs()
	local onGround, overGap, overVoid, examined = 0, 0, 0, 0
	local examples = {}
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.IgnoreWater = false
	for name in pairs(roots) do
		local root = workspace:FindFirstChild(name)
		for _, part in ipairs(root and root:GetDescendants() or {}) do
			if part:IsA("BasePart") and part.Anchored and part.CanCollide then
				local cf, size = part.CFrame, part.Size
				local up = Vector3.new(0, 1, 0)
				local hy = (math.abs(cf.RightVector:Dot(up)) * size.X + math.abs(cf.UpVector:Dot(up)) * size.Y + math.abs(cf.LookVector:Dot(up)) * size.Z) / 2
				local wide = (size.X >= 8 and size.Z >= 8) or (size.X >= 8 and size.Y >= 8) or (size.Y >= 8 and size.Z >= 8)
				if hy * 2 <= 3 and wide then
					examined += 1
					rayParams.FilterDescendantsInstances = { part }
					local hit = workspace:Raycast(part.Position - Vector3.new(0, hy - 0.1, 0), Vector3.new(0, -600, 0), rayParams)
					local status = explain(part)
					if not hit then
						if status == "breakable" then
							overVoid += 1
							if #examples < 10 then
								table.insert(examples, "BREAKABLE OVER THE VOID " .. part:GetFullName())
							end
						end
					elseif hit.Distance <= 3.5 then
						onGround += 1
					else
						overGap += 1
					end
				end
			end
		end
	end
	out("ground slabs: %d wide flat parts; %d lie on the ground or a footing (breakable, ground under them), %d are decks over a gap (breakable: they fall onto what is under them), %d breakable over the void (want 0)",
		examined, onGround, overGap, overVoid)
	for _, e in ipairs(examples) do
		out("  PROBLEM %s", e)
	end
end

-- HOLES THE RULES CAN'T SEE (Oliver 2026-09-24: "some parts on the map are still indestructible").
-- Explain answers for a part that is asked about; these are the ways a part is never asked, or is
-- asked and still can't go:
--   unhittable     collides but CanQuery is off: bullets and blasts (raycasts and GetPartBoundsInRadius)
--                  never find it, so it only goes if something it hangs on does
--   orphan trim    neither collides nor takes a ray, is visible, and is neither a member of a pool
--                  (tagged or a compact thing) nor touching a sibling that takes it along
--                  (dropDressing walks the part's own siblings): nothing ever takes it down
--   loose          unanchored in a match root with no pool (vehicles and debris have their own)
--   outside        solid anchored parts straight under workspace outside the match roots (not the
--                  Lobby, not the pickups in workspace.Loot, which are loot, not the map)
-- Counts by category with at most 5 example groups each. `COVERAGE FAIL` if any category but the
-- allowed ones has anything in it.
local CARRIES = { Wall = true, Floor = true, Roof = true, Gable = true, Parapet = true, Stair = true, Balcony = true }
local ATTACH, SCAN = 0.35, 800
-- Outside the roots on purpose: the lobby; loot (pickups, chests, supply crates: loot, not the map);
-- what players deploy and build (their own health); client fx.
local OUTSIDE_OK = { Lobby = true, Loot = true, SupplyDrops = true, Deployables = true, Defenses = true, Companions = true,
	CrackFx = true, BreakFx = true, Effects = true }

local function tagged(part)
	local node = part
	while node and node ~= workspace do
		if type(node:GetAttribute("Destructible")) == "string" or node:GetAttribute("DestructibleHealth") then
			return true
		end
		node = node.Parent
	end
	return false
end

local function holes(label)
	local cats = { unhittable = {}, ["orphan trim"] = {}, loose = {}, outside = {} }
	local cover, coverSample = 0, {}
	local counts = { unhittable = 0, ["orphan trim"] = 0, loose = 0, outside = 0 }
	local function note(cat, part, root)
		counts[cat] += 1
		local g = (root and labelOf(part, root) or part.Parent and part.Parent.Name or "?") .. " :: " .. part.Name
		cats[cat][g] = (cats[cat][g] or 0) + 1
	end
	local box = OverlapParams.new()
	box.FilterType = Enum.RaycastFilterType.Include
	for name in pairs(roots) do
		local root = workspace:FindFirstChild(name)
		box.FilterDescendantsInstances = { root }
		for _, part in ipairs(root and root:GetDescendants() or {}) do
			if part:IsA("BasePart") then
				if not part.Anchored then
					local model = part:FindFirstAncestorOfClass("Model")
					if not (model and (model:GetAttribute("VehicleId") or model:GetAttribute("Vehicle") or model:FindFirstChildOfClass("VehicleSeat")))
						and not tagged(part) and not part:FindFirstAncestorOfClass("Tool") then
						note("loose", part, root)
					end
				elseif part.CanCollide and not part.CanQuery then
					note("unhittable", part, root)
				elseif not part.CanCollide and not part.CanQuery and part.Transparency < 0.9 and not tagged(part) then
					local goes = false
					local parent = part.Parent
					local siblings = parent and #parent:GetChildren() or 0
					local near = workspace:GetPartBoundsInBox(part.CFrame, part.Size + Vector3.new(ATTACH, ATTACH, ATTACH) * 2, box)
					for _, other in ipairs(near) do
						if other ~= part and other.CanCollide and other.Anchored then
							local status, _, key = explain(other)
							if status == "breakable" then
								if typeof(key) == "Instance" and key:IsA("Model") and part:IsDescendantOf(key) then
									goes = true
								elseif other.Parent == parent and (siblings <= SCAN or CARRIES[other.Name]) then
									goes = true
								end
							end
							if goes then
								break
							end
						end
					end
					if not goes then
						if DS.IsCover and DS.IsCover(part) and DS.ClearCoverInRadius then
							-- Loose cover: a blast takes it, and so does the break of what it lies on.
							cover += 1
							if cover % 97 == 1 and #coverSample < 80 then
								table.insert(coverSample, part)
							end
						else
							note("orphan trim", part, root)
						end
					end
				end
			end
		end
	end
	for _, child in ipairs(workspace:GetChildren()) do
		if not roots[child.Name] and not OUTSIDE_OK[child.Name] and child ~= workspace.Terrain and not child:IsA("Camera") then
			for _, d in ipairs(child:IsA("BasePart") and { child } or child:GetDescendants()) do
				if d:IsA("BasePart") and d.Anchored and (d.CanCollide or d.CanQuery) and not game:GetService("Players"):GetPlayerFromCharacter(d:FindFirstAncestorOfClass("Model")) then
					note("outside", d, nil)
				end
			end
		end
	end
	local bad = 0
	for _, cat in ipairs({ "unhittable", "orphan trim", "loose", "outside" }) do
		bad += counts[cat]
		local list = {}
		for g, n in pairs(cats[cat]) do
			table.insert(list, { g = g, n = n })
		end
		table.sort(list, function(a, b)
			return a.n > b.n
		end)
		local shown = {}
		for i = 1, math.min(5, #list) do
			table.insert(shown, list[i].g .. " x" .. list[i].n)
		end
		out("  holes %-12s %5d  %s%s", cat, counts[cat], table.concat(shown, ", "), #list > 5 and (", +" .. (#list - 5) .. " groups") or "")
	end
	-- Loose cover really goes: a small blast on each sampled piece.
	local sampled, cleared = 0, 0
	for _, part in ipairs(coverSample) do
		if part.Parent then
			sampled += 1
			DS.ClearCoverInRadius(part.Position, 1)
			if not part.Parent then
				cleared += 1
			end
		end
	end
	out("  loose cover %5d  (goes in a blast or with what it lies on): a blast on %d sampled pieces cleared %d", cover, sampled, cleared)
	if sampled > 0 and cleared < sampled * 0.8 then
		bad += sampled - cleared
		out("  PROBLEM loose cover a blast did not clear: %d of %d", sampled - cleared, sampled)
	end
	out("%s holes: %d parts no damage can take down%s", label, bad, bad > 0 and "  COVERAGE FAIL" or "")
	return counts, bad
end

-- The audit's own planted faults: a wall nobody can hit (CanQuery off) in the Map, and a solid part
-- dropped straight under workspace, outside every root. Both must show up as holes.
local function plantedHoles()
	local map = workspace:FindFirstChild("Map")
	local plantWall = Instance.new("Part")
	plantWall.Name = "PlantedUnhittableWall"
	plantWall.Anchored, plantWall.CanCollide, plantWall.CanQuery = true, true, false
	plantWall.Size, plantWall.CFrame = Vector3.new(12, 10, 1), CFrame.new(0, 900, 0)
	plantWall.Parent = map
	local stray = Instance.new("Part")
	stray.Name = "PlantedStrayPart"
	stray.Anchored = true
	stray.Size, stray.CFrame = Vector3.new(4, 4, 4), CFrame.new(0, 920, 0)
	stray.Parent = workspace
	local before = holes("planted")
	plantWall:Destroy()
	stray:Destroy()
	local _, after = holes("planted removed")
	out("planted holes: unhittable wall %s, stray part outside the roots %s",
		before.unhittable > 0 and "caught" or "MISSED", before.outside > 0 and "caught" or "MISSED")
	return after
end

local ok, err = pcall(function()
	for index, spec in ipairs(MAPS) do
		math.randomseed(spec.seed)
		local started = os.clock()
		local okBuild, info = pcall(MapGenerator.Build, spec.id)
		if not okBuild then
			out("MAP BUILD FAILED %s: %s", spec.id, tostring(info))
		else
			if spec.teams then
				local ModeTeams = require(modules:WaitForChild("ModeTeams"))
				local GameModes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameModes"))
				local mode = GameModes.Get("TeamDeathmatch") or { id = "TeamDeathmatch", teams = true }
				local okTeams, why = pcall(ModeTeams.Setup, mode, info)
				out("%s: ModeTeams.Setup %s; battleground %s; bases %s", spec.id, okTeams and "ok" or ("FAILED " .. tostring(why)),
					tostring(ModeTeams.Battleground and ModeTeams.Battleground() ~= nil),
					tostring(ModeTeams.BaseRuin and (ModeTeams.BaseRuin(1) ~= nil and ModeTeams.BaseRuin(2) ~= nil)))
			end
			task.wait(0.5)
			out("%s built in %.1f s", spec.id, os.clock() - started)
			local _, pools = audit(spec.id)
			holes(spec.id)
			if index == #MAPS then
				plantedHoles()
				otherRoots()
				groundSlabs()
				floatingAfterBreaks(pools)
			end
		end
		if index < #MAPS then
			MapGenerator.Clear()
			task.wait(1)
		end
	end
end)
if not ok then
	out("PROBE ERROR: %s", tostring(err))
end
out("done")
