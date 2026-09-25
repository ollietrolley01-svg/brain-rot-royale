-- The battleground's road ends on every map: each of the five maps built (seed 101), a team match set
-- up on it, and its roads audited round the arena -- how many ends were finished (gateways), and any
-- road left stopping short on open ground near the apron's edge (a carriageway piece whose end runs
-- on into nothing, within REACH of the edge, and no gateway there). tools/team_battleground_check.py
-- runs the same audit (between the AUDIT markers) on its mock town. Then objective capture (KOTH) is
-- started on the same arena, and each of its objectives must be the middle of one of the arena's
-- marked capture rings (CaptureRing marks at TeamBattleground.CaptureRadius, in 7 of 12 sectors at least).
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/team_battleground_roadends_probe.lua -WaitSeconds 900 [-PlaceFile <rbxlx>]

-- AUDIT BEGIN
local AUDIT_CARRIAGEWAY = { Asphalt = true, RoadSurface = true, BridgeRoad = true, JunctionAsphalt = true, RoadCurve = true }
-- roadEndAudit(map, centre, outer, reach, roadEnds) -> finished ends, { open ends' descriptions }.
local function roadEndAudit(map, centre, outer, reach, roadEnds)
	local c = Vector3.new(centre.X, 0, centre.Z)
	local near, gates = {}, {}
	for _, part in ipairs(map:GetDescendants()) do
		if part:IsA("BasePart") and AUDIT_CARRIAGEWAY[part.Name] and not part:GetAttribute("TeamBattleground") then
			local d = (Vector3.new(part.Position.X, 0, part.Position.Z) - c).Magnitude
			if d - math.max(part.Size.X, part.Size.Z) / 2 < outer + reach + 20 then
				table.insert(near, part)
			end
		end
	end
	local finished = 0
	for _, e in ipairs(roadEnds and roadEnds:GetChildren() or {}) do
		if e.Name == "RoadEnd" then
			finished = finished + 1
			for _, p in ipairs(e:GetDescendants()) do
				if p.Name == "StopLine" then
					table.insert(gates, Vector3.new(p.Position.X, 0, p.Position.Z))
				end
			end
		end
	end
	local function block(p)
		return p:IsA("Part") and p.Shape == Enum.PartType.Block
	end
	-- A town's own closed street end (MapDecor: a kerb laid across the carriageway's end) is finished too.
	local closers = {}
	for _, part in ipairs(map:GetDescendants()) do
		if part:IsA("BasePart") and part.Name == "Kerb" and not part:GetAttribute("TeamBattleground") then
			local d = (Vector3.new(part.Position.X, 0, part.Position.Z) - c).Magnitude
			if d < outer + reach + 30 then
				table.insert(closers, part)
			end
		end
	end
	local function covered(q, self)
		for _, kerb in ipairs(closers) do
			local l = kerb.CFrame:PointToObjectSpace(Vector3.new(q.X, kerb.Position.Y, q.Z))
			if math.abs(l.X) <= kerb.Size.X / 2 + 1.5 and math.abs(l.Z) <= kerb.Size.Z / 2 + 1.5 and kerb:IsDescendantOf(map) then
				local long = math.max(kerb.Size.X, kerb.Size.Z)
				if long >= 17 then
					return true
				end
			end
		end
		for _, other in ipairs(near) do
			if other ~= self and block(other) then
				local l = other.CFrame:PointToObjectSpace(Vector3.new(q.X, other.Position.Y, q.Z))
				if math.abs(l.X) <= other.Size.X / 2 + 0.1 and math.abs(l.Z) <= other.Size.Z / 2 + 0.1 then
					return true
				end
			end
		end
		return false
	end
	local open = {}
	for _, part in ipairs(near) do
		if block(part) and part.Name ~= "JunctionAsphalt" then
			local cf, size = part.CFrame, part.Size
			local dir, length
			if part.Name == "RoadCurve" then
				dir, length = cf.RightVector, size.X
			elseif part.Name == "RoadSurface" or part.Name == "BridgeRoad" or (part.Name == "Asphalt" and math.abs(size.X - 18) < 0.6 and size.Z < size.X) then
				dir, length = cf.LookVector, size.Z -- RoadNetwork's slabs lie along their LookVector
			elseif math.abs(size.X - size.Z) < 0.5 then
				dir = nil -- square: a junction box, or a street's piece that has no long way
			elseif size.X > size.Z then
				dir, length = cf.RightVector, size.X
			else
				dir, length = cf.LookVector, size.Z
			end
			dir = dir and Vector3.new(dir.X, 0, dir.Z)
			if dir and dir.Magnitude > 0.5 then
				dir = dir.Unit
				for _, sign in ipairs({ -1, 1 }) do
					local mid = Vector3.new(part.Position.X, 0, part.Position.Z) + dir * (sign * length / 2)
					local r = (mid - c).Magnitude
					if r < outer + reach and not covered(mid + dir * (sign * 2), part) then
						local gated = false
						for _, g in ipairs(gates) do
							if (g - mid).Magnitude < 8 then
								gated = true
							end
						end
						if not gated then
							table.insert(open, string.format("%s %s ends %.0f from the middle at (%.0f, %.0f) on open ground (size %.1f x %.1f, look %.2f, %.2f)",
								part.Parent and part.Parent.Name or "?", part.Name, r, mid.X - c.X, mid.Z - c.Z, size.X, size.Z, cf.LookVector.X, cf.LookVector.Z))
						end
					end
				end
			end
		end
	end
	return finished, open
end
-- AUDIT END

if not game or not game:GetService("RunService") then
	return
end
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local MapGenerator = require(modules:WaitForChild("MapGenerator"))
local ModeTeams = require(modules:WaitForChild("ModeTeams"))
local TB = require(modules:WaitForChild("TeamBattleground"))
local KOTH = require(modules:WaitForChild("ModeKingOfTheHill"))
local GameModes = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("GameModes"))
local REACH = 60
local DUMP = false
local function out(fmt, ...)
	print("[ROADENDS] " .. string.format(fmt, ...))
end
local bad = 0
for _, id in ipairs({ "SahurSprings", "TralalaTown", "BombardiroBay", "RotRidge", "PatapimPlains" }) do
	math.randomseed(101)
	local ok, info = pcall(MapGenerator.Build, id)
	if not ok then
		out("%s BUILD FAILED %s", id, tostring(info))
		bad += 1
	else
		local mode = GameModes.Get("TeamDeathmatch") or { id = "TeamDeathmatch", teams = true }
		pcall(ModeTeams.Setup, mode, info)
		local field = ModeTeams.Battleground()
		if not field then
			out("%s NO BATTLEGROUND", id)
			bad += 1
		else
			local finished, open = roadEndAudit(info.map, field.frame.Position, TB.RoadEnd, REACH, field.roadEnds)
			out("%s: %d road ends finished, %d roads stopping short within %d of the edge", id, finished, #open, REACH)
			for _, line in ipairs(open) do
				out("  %s", line)
			end
			if #open > 0 and DUMP then
				local c = field.frame.Position
				for _, p in ipairs(info.map:GetDescendants()) do
					if p:IsA("BasePart") then
						local d = Vector3.new(p.Position.X - c.X, 0, p.Position.Z - c.Z)
						if d.Magnitude > 185 and d.Magnitude < 235 and math.abs(math.atan2(d.Z, d.X)) < 0.2 and p.Size.Y < 3 then
							out("    near %s/%s at (%.1f, %.1f) size %.1f %.1f %.1f look %.2f %.2f", p.Parent.Name, p.Name, d.X, d.Z, p.Size.X, p.Size.Y, p.Size.Z, p.CFrame.LookVector.X, p.CFrame.LookVector.Z)
						end
					end
				end
			end
			if finished < 2 or #open > 0 then
				bad += 1
			end
			-- Objective capture on the same arena.
			local kothMode = GameModes.Get("KingOfTheHill")
			local ok3, err = pcall(KOTH.Start, kothMode, info)
			local positions = ok3 and KOTH.Positions() or {}
			local marks = {}
			for _, p in ipairs(field.model:GetDescendants()) do
				if p.Name == "CaptureRing" then
					table.insert(marks, p.Position)
				end
			end
			local zoned = 0
			for _, centre in ipairs(positions) do
				local sectors, count = {}, 0
				for _, m in ipairs(marks) do
					local d = Vector3.new(m.X - centre.X, 0, m.Z - centre.Z)
					if math.abs(d.Magnitude - TB.CaptureRadius) <= 1.2 and math.abs(m.Y - centre.Y) <= 8 then
						local s = math.floor((math.deg(math.atan2(d.Z, d.X)) % 360) / 30)
						if not sectors[s] then
							sectors[s] = true
							count += 1
						end
					end
				end
				if count >= 7 then
					zoned += 1
				else
					local f = field.frame:PointToObjectSpace(centre)
					out("  objective at local (%.1f, %.2f, %.1f): %d of 12 sectors marked (%d marks on the map's arena)", f.X, f.Y, f.Z, count, #marks)
				end
			end
			out("%s: KOTH %s, %d objectives, %d on marked capture areas", id, ok3 and "started" or ("FAILED " .. tostring(err)), #positions, zoned)
			if #positions ~= 2 or zoned ~= 2 then
				bad += 1
			end
			pcall(KOTH.Stop)
		end
		pcall(ModeTeams.Teardown)
	end
	task.wait(0.5)
end
out("DONE %s", bad == 0 and "PASS" or ("FAIL on " .. bad .. " maps"))
