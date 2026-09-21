-- Town themes label check: which way every piece of text on every theme reads, and a close look at
-- each one that lies flat, from where a player would stand to read it.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/town_themes_label_gallery.lua -OutDir <folder>
--
-- Builds every theme once (TownThemes.BuildAll: set pieces face -Z, props in a row in front) and, for
-- each SurfaceGui, works out the direction its face looks and the direction its text's "up" points:
--   a side face's text is up along the part's +Y; a Top face's along the part's -X (learnt from
--   renders, 2026-09-17: the other way round, every flat label read upside down from the street).
-- Printed: every label facing down, and every upright label whose text is tilted past ~53 degrees.
-- Flat labels should read from the street side (-Z): their "up" must point +Z. Each group of flat
-- labels then gets a view from a player's eye, a few studs toward the street, zoomed in.

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local TownThemes = require(modules:WaitForChild("TownThemes"))

local AUDIT_ORIGIN = Vector3.new(0, 600, 0)
local SLOTS = 24

local function note(fmt, ...)
	print("[BRR_Gallery] note " .. string.format(fmt, ...))
end

local FACE = {
	[Enum.NormalId.Front] = { normal = Vector3.new(0, 0, -1), up = Vector3.new(0, 1, 0) },
	[Enum.NormalId.Back] = { normal = Vector3.new(0, 0, 1), up = Vector3.new(0, 1, 0) },
	[Enum.NormalId.Right] = { normal = Vector3.new(1, 0, 0), up = Vector3.new(0, 1, 0) },
	[Enum.NormalId.Left] = { normal = Vector3.new(-1, 0, 0), up = Vector3.new(0, 1, 0) },
	[Enum.NormalId.Top] = { normal = Vector3.new(0, 1, 0), up = Vector3.new(-1, 0, 0) },
	[Enum.NormalId.Bottom] = { normal = Vector3.new(0, -1, 0), up = Vector3.new(1, 0, 0) },
}

local function v3(v)
	return string.format("(%.2f,%.2f,%.2f)", v.X, v.Y, v.Z)
end

local function pathFrom(root, instance)
	local names = {}
	while instance and instance ~= root do
		table.insert(names, 1, instance.Name)
		instance = instance.Parent
	end
	return table.concat(names, "/")
end

local state = { clusters = {} }

local views = {
	{
		name = "labels_00_audit",
		settle = 1,
		setup = function(_, camera)
			local holder = Instance.new("Folder")
			holder.Name = "BRR_LabelAudit"
			holder.Parent = workspace
			state.holder = holder
			local entries = TownThemes.BuildAll(holder, AUDIT_ORIGIN, 110)
			local total, flatCount, flatWrong, down, tilted = 0, 0, 0, 0, 0
			for _, entry in ipairs(entries) do
				local flats = {}
				for _, gui in ipairs(entry.model:GetDescendants()) do
					if gui:IsA("SurfaceGui") and gui.Parent:IsA("BasePart") then
						total += 1
						local part = gui.Parent
						local face = FACE[gui.Face]
						local normal = part.CFrame:VectorToWorldSpace(face.normal)
						local up = part.CFrame:VectorToWorldSpace(face.up)
						local label = gui:FindFirstChildWhichIsA("TextLabel")
						local text = label and label.Text or "?"
						local where = pathFrom(entry.model, part)
						if normal.Y > 0.7 then
							flatCount += 1
							local ok = up.Z > 0.7
							if not ok then
								flatWrong += 1
							end
							note("FLAT %s %s '%s' up=%s %s", ok and "ok " or "BAD", entry.name .. "/" .. where, text, v3(up),
								ok and "" or (up.Z < -0.7 and "(upside down from the street)" or "(sideways from the street)"))
							local position = part.CFrame:PointToWorldSpace(face.normal * part.Size / 2)
							table.insert(flats, { position = position, text = text, ok = ok })
						elseif normal.Y < -0.7 then
							down += 1
							note("DOWN %s '%s'", entry.name .. "/" .. where, text)
						elseif up.Y < 0.6 then
							tilted += 1
							note("TILTED %s '%s' up=%s", entry.name .. "/" .. where, text, v3(up))
						end
					end
				end
				-- Flat labels within 9 studs of each other share a view.
				for _, flat in ipairs(flats) do
					local home
					for _, cluster in ipairs(state.clusters) do
						if cluster.theme == entry.name and (cluster.center - flat.position).Magnitude < 9 then
							home = cluster
							break
						end
					end
					if not home then
						home = { theme = entry.name, members = {}, center = flat.position }
						table.insert(state.clusters, home)
					end
					table.insert(home.members, flat)
					local sum = Vector3.zero
					for _, member in ipairs(home.members) do
						sum += member.position
					end
					home.center = sum / #home.members
				end
			end
			note("labels: %d total; %d lie flat (%d read wrong from the street); %d face down; %d upright but tilted; %d flat groups to look at",
				total, flatCount, flatWrong, down, tilted, #state.clusters)
			if #state.clusters > SLOTS then
				note("WARNING %d flat groups but only %d view slots", #state.clusters, SLOTS)
			end
			camera.CFrame = CFrame.lookAt(AUDIT_ORIGIN + Vector3.new(900, 250, -400), AUDIT_ORIGIN + Vector3.new(900, 0, 0))
		end,
	},
}

for index = 1, SLOTS do
	table.insert(views, {
		name = string.format("labels_%02d", index),
		settle = 1.5,
		setup = function(_, camera)
			local cluster = state.clusters[index]
			if not cluster then
				camera.CFrame = CFrame.lookAt(AUDIT_ORIGIN + Vector3.new(0, 900, 1), AUDIT_ORIGIN)
				return
			end
			local texts = {}
			for _, member in ipairs(cluster.members) do
				table.insert(texts, member.text .. (member.ok and "" or "(BAD)"))
			end
			note("group %d %s: %s", index, cluster.theme, table.concat(texts, ", "))
			-- A player a few studs toward the street, eyes about five studs above the labels.
			local spread = 0
			for _, member in ipairs(cluster.members) do
				spread = math.max(spread, (member.position - cluster.center).Magnitude)
			end
			camera.FieldOfView = 45
			camera.CFrame = CFrame.lookAt(cluster.center + Vector3.new(0, 5 + spread * 0.4, -6 - spread * 0.9), cluster.center)
		end,
	})
end

table.insert(views, {
	name = "labels_99_cleanup",
	settle = 0.5,
	setup = function(_, camera)
		if state.holder then
			state.holder:Destroy()
		end
		camera.CFrame = CFrame.lookAt(Vector3.new(0, 900, 1), Vector3.zero)
	end,
})

return views
