-- Task 19 booth gallery: each booth from where a player walks up to it, camera on the booth, for tools/gallery.ps1:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/lobby_booths_gallery.lua -PlaceFile <copy> -OutDir <folder> -TimeoutSeconds 1500
--
-- Builds the real lobby (LobbyService.Build) plus the spawn pad MatchService adds, then shoots: the
-- whole island, each booth (Cosmetics, Crate Altar, Daily Spin, Trade Board) from the plaza in front
-- of it at a player's eye, the row from the pitch road and from the plaza, and the row from above.

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local Lighting = game:GetService("Lighting")

local BASE = Vector3.new(0, 2000, 0)
local V = Vector3.new

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function shot(name, eye, target, fov, extra)
	return {
		name = name,
		settle = 1.2,
		hold = 2,
		setup = function(_, camera)
			if extra then
				extra()
			end
			camera.FieldOfView = fov or 70
			camera.CFrame = CFrame.lookAt(BASE + eye, BASE + target)
		end,
	}
end

local function dusk()
	Lighting.ClockTime = 18.4
	Lighting.Brightness = 1.2
end

local views = {
	{
		name = "00_overview",
		settle = 3,
		hold = 1,
		setup = function(_, camera)
			Lighting.ClockTime = 14
			local LobbyService = require(modules:WaitForChild("LobbyService"))
			local folder = Instance.new("Folder")
			folder.Name = "Lobby"
			folder.Parent = workspace
			local ok, err = pcall(LobbyService.Build, folder, BASE)
			note("lobby build " .. (ok and "ok" or tostring(err)))
			local count = 0
			for _, d in ipairs(folder:GetDescendants()) do
				if d:IsA("BasePart") then
					count += 1
				end
			end
			note("lobby parts " .. count)
			local pad = Instance.new("Part")
			pad.Name = "LobbySpawn"
			pad.Anchored = true
			pad.Size = V(LobbyService.SpawnHalfWidth * 2, 1, 22)
			pad.CFrame = CFrame.new(BASE + LobbyService.SpawnOffset)
			pad.Color = Color3.fromRGB(120, 200, 255)
			pad.Material = Enum.Material.Neon
			pad.Transparency = 0.35
			pad.Parent = folder
			camera.FieldOfView = 60
			camera.CFrame = CFrame.lookAt(BASE + V(150, 150, 210), BASE + V(-10, 0, 10))
		end,
	},
	shot("01_cosmetics_walkup", V(-15, 7, -41), V(-23.9, 4, -65.8), 70),
	shot("02_crate_altar_walkup", V(0, 7, -44), V(0, 4, -72), 70),
	shot("03_daily_spin_walkup", V(15, 7, -37), V(26, 5, -66), 70),
	shot("04_trade_board_walkup", V(-50, 7, -50), V(-68.6, 4, -68.6), 70),
	shot("05_row_from_the_pitch_road", V(-42, 7, -2), V(-38, 4, -50), 70),
	shot("06_row_from_the_plaza", V(8, 9, -30), V(-30, 4, -66), 75),
	shot("07_row_overhead", V(-20, 150, -20), V(-20, 0, -55), 60),
}

return views
