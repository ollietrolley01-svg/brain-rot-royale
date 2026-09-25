-- Lobby v2 gallery (the Rot Road and the district gates), for tools/gallery.ps1:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/lobby_v2_gallery.lua -PlaceFile <copy> -OutDir <folder> -TimeoutSeconds 1500
--
-- Builds the real lobby (LobbyService.Build) plus the spawn pad MatchService adds, then shoots: the
-- whole island, what a player sees on spawning, each district from where a player walks up to it,
-- the ready pad's gate, the leaderboards, and the island and the spawn view again at dusk.

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
	shot("01_spawn_view", V(0, 6.5, 112), V(0, 5, 40), 70),
	shot("02_pier_head_fork", V(0, 14, 104), V(0, 0, 30), 70),
	shot("03_range_gate", V(2, 6, 24), V(40, 8, -2), 70),
	shot("04_pitch_gate", V(-22, 6, 20), V(-60, 6, -2), 70),
	shot("05_market_gate", V(-58, 7, -8), V(-30, 7, -58), 70),
	shot("06_crates_spin_gate", V(-40, 8, -50), V(10, 6, -66), 70),
	shot("07_crates_altar_spin", V(8, 9, -38), V(8, 4, -75), 75),
	shot("08_leaderboards", V(0, 8, 58), V(0, 10, 90), 80),
	shot("09_all_aboard_ready", V(0, 7, 104), V(0, 8, 150), 70),
	shot("10_plan", V(0, 260, 1), V(0, 0, 0), 60),
	shot("11_dusk_overview", V(150, 150, 210), V(-10, 0, 10), 60, dusk),
	shot("12_dusk_spawn_view", V(0, 6.5, 112), V(0, 5, 40), 70, dusk),
}

return views
