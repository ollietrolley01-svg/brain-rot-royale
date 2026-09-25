-- The sound polish, on camera and measured (pc/sound-polish, 2026-09-25).
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/sound_gallery.lua -OutDir <folder> -PlaceFile <build>
--
-- Each view plays real cues from SoundConfig in the edit-mode Studio window and builds them as bars
-- you can see: one bar per cue, height = its direct level (volume x the RMS of its direct layers,
-- what tools/sound_polish_check.py holds to the calibre bands), colour by family, a label with the
-- name, the level, the reach and the engine's own PlaybackLoudness peak (which reads 0 in edit mode:
-- Studio renders no audio there, so the level is the number to read). The last
-- view lays each calibre's reach out down a range at 1:10, so "a sniper carries four times as far as
-- an SMG" is a thing you look at. Every number is also printed as "[BRR_Gallery] note ...".

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SoundConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SoundConfig"))

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local FIREARMS = {
	"GunshotSuppressed", "GunshotSMG", "GunshotPistol", "GunshotRevolver", "GunshotRifle", "GunshotHeavy",
	"GunshotLMG", "GunshotShotgun", "GunshotDMR", "GunshotSniper", "GunshotCannon",
}
local BLASTS = { "ExplosionGrenade", "ExplosionFrag", "ExplosionMine", "ExplosionRocket", "ExplosionBarrel", "ExplosionVehicle" }
local NOVELTY = {
	"GunshotBubble", "GunshotSquirt", "GunshotSqueak", "GunshotKeycap", "GunshotPopper",
	"ExplosionParty", "ExplosionSlipper", "ExplosionFidget", "ExplosionGold", "ExplosionCoffee",
}

local COLOURS = {
	gun = Color3.fromRGB(235, 120, 60), blast = Color3.fromRGB(230, 60, 50), novelty = Color3.fromRGB(120, 200, 255),
}

local function label(parent, text, size)
	local board = Instance.new("Part")
	board.Anchored = true
	board.CanCollide = false
	board.Size = size or Vector3.new(7, 3, 0.2)
	board.Color = Color3.fromRGB(24, 24, 28)
	board.Parent = parent
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.PixelsPerStud = 40
	gui.Parent = board
	local text_ = Instance.new("TextLabel")
	text_.Size = UDim2.fromScale(1, 1)
	text_.BackgroundTransparency = 1
	text_.TextColor3 = Color3.new(1, 1, 1)
	text_.TextScaled = true
	text_.Font = Enum.Font.GothamBold
	text_.Text = text
	text_.Parent = gui
	return board
end

-- The cue's direct layers (what anyone near it hears: no room/echo, no far thump, no shooter-only
-- layers) as Sounds with its own effects, played together; the peak of their summed loudness.
local function measure(name, parent)
	local cue = SoundConfig.Get(name)
	local sounds = {}
	for _, layer in ipairs(SoundConfig.LayersOf(cue)) do
		if not (layer.where or layer.who or layer.range) then
			local sound = Instance.new("Sound")
			sound.SoundId = layer.id
			sound.Volume = layer.volume
			sound.PlaybackSpeed = layer.pitch
			for _, effect in ipairs(cue.effects or {}) do
				local ok, instance = pcall(Instance.new, effect[1])
				if ok then
					for property, value in pairs(effect[2] or {}) do
						pcall(function()
							instance[property] = value
						end)
					end
					instance.Parent = sound
				end
			end
			sound.Parent = parent
			table.insert(sounds, { sound = sound, delay = layer.delay })
		end
	end
	for _ = 1, 20 do
		local loaded = true
		for _, entry in ipairs(sounds) do
			loaded = loaded and entry.sound.IsLoaded
		end
		if loaded then
			break
		end
		task.wait(0.1)
	end
	for _, entry in ipairs(sounds) do
		task.delay(entry.delay, function()
			entry.sound:Play()
		end)
	end
	local peak, started = 0, os.clock()
	while os.clock() - started < 0.7 do
		local sum = 0
		for _, entry in ipairs(sounds) do
			sum += entry.sound.PlaybackLoudness
		end
		peak = math.max(peak, sum)
		task.wait()
	end
	for _, entry in ipairs(sounds) do
		entry.sound:Destroy()
	end
	return peak
end

local function directLevel(cue)
	local total = 0
	for _, layer in ipairs(SoundConfig.LayersOf(cue)) do
		if not (layer.where or layer.who or layer.range) then
			total += layer.volume ^ 2
		end
	end
	return math.sqrt(total)
end

-- A row of bars for `names`, measured one after another, the camera on the row throughout.
local function barRow(folder, camera, names, family)
	local spacing = 9
	local width = (#names - 1) * spacing
	local view = CFrame.lookAt(Vector3.new(width / 2, 20, -62), Vector3.new(width / 2, 8, 0))
	camera.CFrame = view
	local rows = {}
	for index, name in ipairs(names) do
		local cue = SoundConfig.Get(name)
		local x = (index - 1) * spacing
		local speaker = Instance.new("Part")
		speaker.Anchored = true
		speaker.Size = Vector3.new(3, 3, 3)
		speaker.Position = Vector3.new(x, 1.5, 0)
		speaker.Material = Enum.Material.Neon
		speaker.Color = Color3.new(1, 1, 1)
		speaker.Parent = folder
		local peak = measure(name, speaker)
		camera.CFrame = view
		speaker.Color = COLOURS[family(name)] or Color3.new(1, 1, 1)
		local height = math.max(0.3, directLevel(cue) * 16)
		local bar = Instance.new("Part")
		bar.Anchored = true
		bar.Size = Vector3.new(5, height, 5)
		bar.Position = Vector3.new(x, 3 + height / 2, 0)
		bar.Color = COLOURS[family(name)] or Color3.new(1, 1, 1)
		bar.Material = Enum.Material.SmoothPlastic
		bar.Parent = folder
		local _, far = SoundConfig.Rolloff(name, cue)
		local board = label(folder, string.format("%s\npeak %.0f  lvl %.2f\nreach %d", (string.gsub(name, "^Gunshot", "")),
			peak, directLevel(cue), far), Vector3.new(8, 3.2, 0.2))
		board.CFrame = CFrame.new(x, -1.2, -3)
		table.insert(rows, { name = name, peak = directLevel(cue) })
		note(string.format("%s peak %.1f level %.3f reach %d class %s jitter %.2f", name, peak, directLevel(cue), far,
			SoundConfig.ClassOf(name, cue), SoundConfig.JitterOf(name, cue)))
	end
	camera.CFrame = view
	return rows
end

local function ordered(rows)
	local bad = {}
	for index = 2, #rows do
		if rows[index].peak + 1e-6 < rows[index - 1].peak * 0.9 then
			table.insert(bad, rows[index - 1].name .. ">" .. rows[index].name)
		end
	end
	return bad
end

return {
	{
		name = "sound_firearms_by_calibre",
		setup = function(folder, camera)
			local rows = barRow(folder, camera, FIREARMS, function()
				return "gun"
			end)
			local bad = ordered(rows)
			note(string.format("firearms quietest->loudest by calibre: %d inversions beyond 10%% %s", #bad,
				table.concat(bad, " ")))
		end,
	},
	{
		name = "sound_blasts_by_size",
		setup = function(folder, camera)
			local rows = barRow(folder, camera, BLASTS, function()
				return "blast"
			end)
			local bad = ordered(rows)
			note(string.format("blasts smallest->biggest: %d inversions beyond 10%% %s", #bad, table.concat(bad, " ")))
		end,
	},
	{
		name = "sound_novelty",
		setup = function(folder, camera)
			barRow(folder, camera, NOVELTY, function()
				return "novelty"
			end)
			note("novelty: bubble/squirt/squeak/keycap/popper and the five silly blasts, played for real")
		end,
	},
	{
		name = "sound_reach_by_calibre",
		setup = function(folder, camera)
			-- Down range at 1:10: each calibre's positional reach, and (past it) how far its far thump carries.
			local scale = 0.1
			for index, name in ipairs(FIREARMS) do
				local cue = SoundConfig.Get(name)
				local _, far = SoundConfig.Rolloff(name, cue)
				local z = (index - 1) * 6
				local lane = Instance.new("Part")
				lane.Anchored = true
				lane.Size = Vector3.new(far * scale, 0.6, 3)
				lane.Position = Vector3.new(far * scale / 2, 0.3, z)
				lane.Color = COLOURS.gun
				lane.Parent = folder
				local carry = 0
				if cue.distant then
					carry = SoundConfig.Get(cue.distant.cue).maxDistance
					local tail = Instance.new("Part")
					tail.Anchored = true
					tail.Size = Vector3.new((carry - far) * scale, 0.3, 2)
					tail.Position = Vector3.new((far + (carry - far) / 2) * scale, 0.15, z)
					tail.Color = Color3.fromRGB(120, 90, 70)
					tail.Transparency = 0.3
					tail.Parent = folder
				end
				local board = label(folder, string.format("%s %d%s", (string.gsub(name, "^Gunshot", "")), far,
					carry > 0 and string.format(" (+thump to %d)", carry) or ""), Vector3.new(14, 2.4, 0.2))
				board.CFrame = CFrame.new(-8, 1.4, z) * CFrame.Angles(0, math.pi / 2, 0)
				note(string.format("%s reach %d far-thump %d", name, far, carry))
			end
			camera.CFrame = CFrame.lookAt(Vector3.new(70, 150, -60), Vector3.new(70, 0, 30))
		end,
	},
}
