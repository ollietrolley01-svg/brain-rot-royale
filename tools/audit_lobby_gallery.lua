-- Lobby structures gallery, for tools/gallery.ps1:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/audit_lobby_gallery.lua -OutDir <folder> -TimeoutSeconds 900
--
-- Builds the real lobby and photographs the buildings from outside and inside, from where a player
-- stands, looking at the places holes show: wall tops under roofs, roof edges, awnings against the
-- walls behind them, rigging where it should meet the balloon. Positions follow LobbyService's
-- layout (angles from +X toward +Z; each piece's -Z faces the plaza centre).

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")

local BASE = Vector3.new(0, 2000, 0)
local state = {}

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function spot(degrees, radius)
	local angle = math.rad(degrees)
	return BASE + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
end

local function facing(position)
	return CFrame.lookAt(position, Vector3.new(BASE.X, position.Y, BASE.Z))
end

local views = {
	{
		name = "lobby_build",
		settle = 2,
		hold = 1,
		setup = function(_, camera)
			local LobbyService = require(modules:WaitForChild("LobbyService"))
			local folder = Instance.new("Folder")
			folder.Name = "Lobby"
			folder.Parent = workspace
			local ok, err = pcall(LobbyService.Build, folder, BASE)
			note("lobby build " .. (ok and "ok" or tostring(err)))
			state.folder = folder
			camera.FieldOfView = 70
			camera.CFrame = CFrame.lookAt(BASE + Vector3.new(0, 160, 230), BASE)
			if ok then
				state.addLabelViews(folder)
			end
		end,
	},
}

-- Every SurfaceGui in the lobby from where a player reads it, appended once the lobby is built (the
-- gallery walks `views` with ipairs, so views added now are shot at the end). A face looking out
-- sideways is shot straight on, from a little below if it's high up; a face looking up (a console,
-- a key) from a standing player's eye height on the side it tilts toward, or else the plaza's side.
-- Text on its side or squashed shows at a glance.
function state.addLabelViews(folder)
	local count = 0
	for _, gui in ipairs(folder:GetDescendants()) do
		local part = gui:IsA("SurfaceGui") and gui.Parent
		if part and part:IsA("BasePart") then
			count += 1
			local face = Vector3.fromNormalId(gui.Face)
			local normal = part.CFrame:VectorToWorldSpace(face)
			local centre = part.CFrame * (face * part.Size / 2)
			local across = part.Size - Vector3.new(math.abs(face.X) * part.Size.X, math.abs(face.Y) * part.Size.Y, math.abs(face.Z) * part.Size.Z)
			local span = math.max(across.X, across.Y, across.Z)
			local distance = math.clamp(span * 1.15, 5, 45)
			local eye
			if math.abs(normal.Y) > 0.6 then
				local flat = Vector3.new(normal.X, 0, normal.Z)
				local toward = flat.Magnitude > 0.15 and flat.Unit
					or Vector3.new(BASE.X - centre.X, 0, BASE.Z - centre.Z).Unit
				eye = centre + toward * math.max(4, distance * 0.7)
				eye = Vector3.new(eye.X, math.max(BASE.Y + 5, centre.Y + 1.5), eye.Z)
			else
				eye = centre + normal * distance
				eye = Vector3.new(eye.X, math.max(BASE.Y + 5, eye.Y - distance * 0.35), eye.Z)
			end
			local text = ""
			for _, d in ipairs(gui:GetDescendants()) do
				if d:IsA("TextLabel") and d.Text ~= "" then
					text = d.Text
					break
				end
			end
			local label = string.gsub(string.sub(text, 1, 18), "[^%w]", "")
			table.insert(views, {
				name = string.format("label_%02d_%s_%s", count, part.Name, label),
				settle = 1.2,
				hold = 2,
				setup = function(_, camera)
					camera.FieldOfView = 50
					camera.CFrame = CFrame.lookAt(eye, centre)
				end,
			})
		end
	end
	note(string.format("label views added: %d SurfaceGuis", count))
end

local function add(name, eyeLocal, targetLocal, frameFn, fov)
	table.insert(views, {
		name = name,
		settle = 1.2,
		hold = 2,
		setup = function(_, camera)
			local frame = frameFn()
			camera.FieldOfView = fov or 70
			camera.CFrame = CFrame.lookAt(frame * eyeLocal, frame * targetLocal)
		end,
	})
end

local V = Vector3.new
local hall = function()
	return facing(spot(225, 88))
end
add("tradinghall_front", V(-8, 6, -40), V(0, 10, 0), hall, 60)
add("tradinghall_side_back", V(-26, 26, 32), V(-10, 16, 6), hall, 55)
add("tradinghall_roof_sign", V(0, 12, -36), V(0, 18.5, -13), hall, 40)
add("tradinghall_bench", V(6, 5, 7), V(15, 3, 1), hall, 70)
add("tradinghall_back_top", V(10, 20, 36), V(0, 16, 12), hall, 55)
add("tradinghall_inside_up_side", V(10, 4, 2), V(-17, 15.5, 0), hall, 75)
add("tradinghall_inside_up_back", V(0, 4, -6), V(0, 15.5, 12), hall, 75)

local stall = function()
	return facing(spot(250, 74))
end
add("cosmetics_front", V(4, 6, -22), V(0, 6, 0), stall, 60)
add("cosmetics_side", V(-18, 9, 3), V(0, 8, 1), stall, 60)
add("cosmetics_inside_up", V(4.5, 3.5, -2.5), V(0, 11, 4), stall, 80)
add("cosmetics_front_close", V(0, 5, -14), V(0, 6, 0), stall, 60)
add("cosmetics_above", V(-6, 22, 12), V(0, 9, 0), stall, 60)

local altar = function()
	return facing(spot(270, 84))
end
add("altar_pillar_top", V(-18, 20, -18), V(-7.8, 17, -7.8), altar, 45)
add("altar_overview", V(0, 14, -40), V(0, 8, 0), altar, 60)
add("altar_console_player", V(0, 5.2, -22), V(0, 2.8, -14.8), altar, 45)

local spin = function()
	return facing(spot(292, 74))
end
add("dailyspin_front", V(0, 8, -34), V(0, 12, 1), spin, 60)
add("dailyspin_side", V(-30, 10, 4), V(0, 12, 1), spin, 60)

local ship = function()
	return CFrame.new(BASE + V(0, 0, 172))
end
add("airship_side", V(-70, 20, -2), V(0, 22, -2), ship, 60)
add("airship_below_balloon", V(-14, 8, 0), V(-11, 28, -6), ship, 70)
add("airship_top", V(-40, 70, -30), V(0, 30, 0), ship, 55)
add("airship_nameboard", V(-40, 36, -30), V(-15, 36, -2), ship, 50)
add("airship_name", V(-80, 40, -40), V(0, 45, -2), ship, 55)

-- The arena terrace: the podium guns and their labels, the targets and the practice sign.
local arena = function()
	return CFrame.new(BASE + V(86, 8, 0))
end
add("arena_podiums", V(-30, 6, -26), V(-10, 4, 0), arena, 60)
add("arena_podium_close", V(-20, 6, -8), V(-10, 5, -18), arena, 55)
add("arena_targets_sign", V(-28, 8, 0), V(20, 12, 0), arena, 60)

local island = function()
	return CFrame.new(BASE)
end
-- The underside from level with the rock's first step (the slit used to run right through here),
-- a tree's foot and the rim rail's posts on the grass.
add("island_underside", V(0, -14, 230), V(0, -20, 0), island, 45)
add("island_tree_foot", V(44, 3, -86), V(57, 1, -98.7), island, 50)
add("island_rim_rail", V(0, 3, -118), V(-26, 1, -127), island, 55)

local pier = function()
	return CFrame.new(BASE + V(0, 0, 96))
end
add("pier_arch", V(0, 7, -24), V(0, 10, 0), pier, 60)

local statue = function()
	return CFrame.new(BASE + V(0, 0, 30))
end
add("statue_base", V(10, 5, 12), V(0, 3, 0), statue, 60)

local boards = function()
	return facing(spot(60, 88))
end
add("board_pylon", V(0, 8, -20), V(0, 8, 0), boards, 60)
add("walk_of_fame", V(0, 6, -30), V(0, 5, 4), function()
	return facing(spot(150, 88))
end, 60)

return views
