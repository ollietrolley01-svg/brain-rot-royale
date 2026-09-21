-- Can a phone player reach the controls? (Oliver's #62 merge dialog, and #10/#54's mode scoreline.)
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/phone_reach_gallery.lua -OutDir <dir>
--
-- Two things, both about a control being ON the screen rather than looking right in isolation.
--
-- MERGE DIALOG. The card is 500x436 with CANCEL and MERGE at y 372..416, and nothing scaled it, so
-- on an 844x390 phone a player could open a merge and never reach the confirm button. The fix folds
-- PhoneLayout's fit into the open animation's rest values (the card's UIScale IS that animation, so
-- a separate write would be overwritten on the first tween frame). Rendered fitted and unfitted, the
-- unfitted one being the planted fault: if both look the same, the picture is proving nothing.
--
-- MODE SCORELINE. The TDM and KOTH readout, drawn at the three forms from the same numbers the
-- client script uses, so its "sized so it does not get in the way" claim can be looked at.
--
-- Both are drawn in the BUILT PLACE from the real modules where a module exists.

local StarterPlayer = game:GetService("StarterPlayer")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Scripts = StarterPlayer:WaitForChild("StarterPlayerScripts")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local MergeDialog = require(Scripts:WaitForChild("MergeDialog"))
local PhoneLayout = require(Scripts:WaitForChild("PhoneLayout"))
local UiKit = require(Scripts:WaitForChild("UiKit"))
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local GameModes = require(Shared:WaitForChild("GameModes"))

local create = UiKit.create
local Role, Type, Radius = UiKit.Role, UiKit.Type, UiKit.Radius

local views = {}
local function note(text)
	print("[BRR_Gallery] note " .. text)
end

-- A frame standing in for a phone screen, so several sizes can be seen at once in one capture.
local function screen(parent, size, x, y, caption)
	local holder = create("Frame", {
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(size.X, size.Y),
		BackgroundColor3 = Color3.fromRGB(26, 30, 40),
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = parent,
	})
	create("UIStroke", { Color = Role.Line, Thickness = 1, Parent = holder })
	create("TextLabel", {
		Position = UDim2.fromOffset(0, -20),
		Size = UDim2.fromOffset(size.X, 18),
		BackgroundTransparency = 1,
		Font = Type.Label.Font,
		Text = caption,
		TextColor3 = Role.TextMuted,
		TextSize = Type.Label.Size,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = holder.Parent,
	}).Position = UDim2.fromOffset(x, y - 20)
	return holder
end

local function gui()
	local screenGui = Instance.new("ScreenGui")
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false
	screenGui.Parent = game:GetService("CoreGui")
	return screenGui
end

table.insert(views, {
	name = "merge_dialog_phone_reach",
	settle = 1.4,
	setup = function(_, camera)
		local root = gui()
		local sheet = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(1800, 520),
			BackgroundColor3 = Role.Base,
			BorderSizePixel = 0,
			Parent = root,
		}, { UiKit.rounded(16) })
		create("UIScale", {
			Scale = math.min(camera.ViewportSize.X * 0.94 / 1800, camera.ViewportSize.Y * 0.86 / 520),
			Parent = sheet,
		})
		create("TextLabel", {
			Position = UDim2.fromOffset(24, 12),
			Size = UDim2.fromOffset(1700, 34),
			BackgroundTransparency = 1,
			Font = Type.Display.Font,
			Text = "Merge dialog on a phone — fitted vs the planted fault",
			TextColor3 = Role.Text,
			TextSize = Type.Display.Size,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = sheet,
		})

		local def = BrainrotData.Get("Bombardiro Crocodilo")
		local results = {}

		local function place(x, size, label, unfitted)
			local holder = screen(sheet, size, x, 96, label)
			-- MergeDialog reads the real viewport for its fit, so for a stand-in screen the same
			-- maths is applied here with that screen's size. `unfitted` is the planted fault: the
			-- scale the card had before this fix, which is to say none.
			local fit = unfitted and 1 or PhoneLayout.PanelScale(Vector2.new(500, 436), size, { inset = true })
			MergeDialog.Close()
			local card = MergeDialog.Open(holder, { def = def, stars = 1, level = 3, count = 3, instant = true })
			if not card then
				note("merge: MergeDialog.Open returned nil for " .. label)
				return
			end
			local scale = holder:FindFirstChildOfClass("Frame")
			for _, item in ipairs(holder:GetDescendants()) do
				if item:IsA("UIScale") then
					item.Scale = fit
					scale = item
				end
			end
			-- Where does the confirm button's bottom edge land on this screen?
			local bottom = size.Y / 2 + (436 * fit) / 2
			local confirmBottom = size.Y / 2 - (436 * fit) / 2 + 416 * fit
			results[#results + 1] = string.format("%s: fit %.3f, confirm bottom %.0f of %d -> %s",
				label, fit, confirmBottom, size.Y, confirmBottom <= size.Y and "ON SCREEN" or "OFF SCREEN")
			note(string.format("merge %s: fit %.3f, card bottom %.0f, confirm bottom %.0f, screen %d -> %s",
				label, fit, bottom, confirmBottom, size.Y, confirmBottom <= size.Y and "reachable" or "UNREACHABLE"))
		end

		place(24, Vector2.new(844, 390), "844x390 — fitted (the fix)", false)
		place(920, Vector2.new(844, 390), "844x390 — UNFITTED, the planted fault", true)
		for _, line in ipairs(results) do
			note("  " .. line)
		end
	end,
})

table.insert(views, {
	name = "mode_scoreline",
	settle = 1.0,
	setup = function(_, camera)
		local root = gui()
		local sheet = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(1500, 640),
			BackgroundColor3 = Role.Base,
			BorderSizePixel = 0,
			Parent = root,
		}, { UiKit.rounded(16) })
		create("UIScale", {
			Scale = math.min(camera.ViewportSize.X * 0.94 / 1500, camera.ViewportSize.Y * 0.86 / 640),
			Parent = sheet,
		})
		create("TextLabel", {
			Position = UDim2.fromOffset(24, 12),
			Size = UDim2.fromOffset(1400, 34),
			BackgroundTransparency = 1,
			Font = Type.Display.Font,
			Text = "Team-mode scoreline — TDM and KOTH, at each form",
			TextColor3 = Role.Text,
			TextSize = Type.Display.Size,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = sheet,
		})

		-- The readout, drawn from the same numbers ModeScoreHud uses.
		local function scoreline(parent, x, y, width, scoresA, scoresB, target, koth, secondsLeft)
			local k = width / 420
			local holder = create("Frame", {
				Position = UDim2.fromOffset(x, y),
				Size = UDim2.fromOffset(width, 44 * k),
				BackgroundColor3 = Role.Base,
				BackgroundTransparency = 0.25,
				BorderSizePixel = 0,
				Parent = parent,
			}, { UiKit.rounded(Radius.Card) })
			create("UIStroke", { Color = Role.Line, Thickness = 1, Transparency = 0.4, Parent = holder })

			local function side(anchorX, value, align, teamIndex)
				local column = create("Frame", {
					AnchorPoint = Vector2.new(anchorX, 0),
					Position = UDim2.new(anchorX, anchorX == 0 and 12 * k or -12 * k, 0, 6 * k),
					Size = UDim2.fromOffset(150 * k, 32 * k),
					BackgroundTransparency = 1,
					Parent = holder,
				})
				create("TextLabel", {
					BackgroundTransparency = 1,
					Font = Type.Heading.Font,
					Text = tostring(value),
					TextColor3 = GameModes.TeamColor(teamIndex),
					TextSize = Type.Heading.Size * k,
					TextXAlignment = align,
					Size = UDim2.new(1, 0, 0, 20 * k),
					Parent = column,
				})
				local track = create("Frame", {
					Position = UDim2.fromOffset(0, 24 * k),
					Size = UDim2.new(1, 0, 0, 8 * k),
					BackgroundColor3 = Role.SurfaceAlt,
					BorderSizePixel = 0,
					Parent = column,
				}, { UiKit.rounded(Radius.Pill) })
				create("Frame", {
					AnchorPoint = Vector2.new(anchorX, 0),
					Position = UDim2.fromScale(anchorX, 0),
					Size = UDim2.fromScale(math.clamp(value / target, 0, 1), 1),
					BackgroundColor3 = GameModes.TeamColor(teamIndex),
					BorderSizePixel = 0,
					Parent = track,
				}, { UiKit.rounded(Radius.Pill) })
			end
			side(0, scoresA, Enum.TextXAlignment.Left, 1)
			side(1, scoresB, Enum.TextXAlignment.Right, 2)

			local caption = "FIRST TO " .. target
			local captionColor = Role.TextMuted
			if koth then
				local lead = math.abs(scoresA - scoresB)
				local leader = scoresA == scoresB and nil or (scoresA > scoresB and 1 or 2)
				caption = string.format("%d:%02d", secondsLeft // 60, secondsLeft % 60)
					.. "\n" .. (leader and (GameModes.TeamName(leader) .. " +" .. lead .. "s") or "level")
				captionColor = leader and GameModes.TeamColor(leader) or Role.TextMuted
			end
			create("TextLabel", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(120 * k, 44 * k),
				BackgroundTransparency = 1,
				Font = Type.Label.Font,
				Text = caption,
				TextColor3 = captionColor,
				TextSize = Type.Label.Size * k,
				TextWrapped = true,
				Parent = holder,
			})
			return holder
		end

		local specs = {
			{ "large 1920x1080", Vector2.new(1920, 1080), 420 },
			{ "short 844x390", Vector2.new(844, 390), 336 },
			{ "tall 375x667", Vector2.new(375, 667), 336 },
		}
		local x = 24
		for _, spec in ipairs(specs) do
			local shown = Vector2.new(math.min(spec[2].X, 460), math.min(spec[2].Y, 260))
			local holder = screen(sheet, shown, x, 90, spec[1] .. " (top of screen)")
			scoreline(holder, (shown.X - spec[3]) / 2, 72 * (spec[3] / 420), spec[3], 62, 47, 100, false, 0)
			scoreline(holder, (shown.X - spec[3]) / 2, 150 * (spec[3] / 420), spec[3], 188, 165, 250, true, 214)
			note(string.format("scoreline %s: width %d, height %d (%.1f%% of screen height)",
				spec[1], spec[3], math.floor(44 * spec[3] / 420), 100 * (44 * spec[3] / 420) / spec[2].Y))
			x += shown.X + 40
		end
	end,
})

-- #14: the ability tile's new home and its readout. Built from the real module.
table.insert(views, {
	name = "ability_tile_readout",
	settle = 1.0,
	setup = function(_, camera)
		local CompanionAbilityIcon = require(Scripts:WaitForChild("CompanionAbilityIcon"))
		local root = gui()
		local sheet = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(1320, 560),
			BackgroundColor3 = Role.Base,
			BorderSizePixel = 0,
			Parent = root,
		}, { UiKit.rounded(16) })
		create("UIScale", {
			Scale = math.min(camera.ViewportSize.X * 0.94 / 1320, camera.ViewportSize.Y * 0.86 / 560),
			Parent = sheet,
		})
		create("TextLabel", {
			Position = UDim2.fromOffset(24, 12),
			Size = UDim2.fromOffset(1260, 34),
			BackgroundTransparency = 1,
			Font = Type.Display.Font,
			Text = "Ability tile — beside the hotbar, with DPS and health",
			TextColor3 = Role.Text,
			TextSize = Type.Display.Size,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = sheet,
		})

		-- A stand-in 1920x1080 screen with the hotbar's footprint marked, so the tile can be seen in
		-- relation to the thing it was moved to sit beside.
		local screenFrame = screen(sheet, Vector2.new(1240, 440), 24, 90, "1920x1080, scaled — hotbar footprint outlined")
		local k = 1240 / 1920
		create("Frame", {
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -16 * k, 1, -16 * k),
			Size = UDim2.fromOffset(690 * k, 150 * k),
			BackgroundColor3 = Role.SurfaceAlt,
			BackgroundTransparency = 0.5,
			BorderSizePixel = 0,
			Parent = screenFrame,
		}, { UiKit.rounded(8) })
		create("TextLabel", {
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -24 * k, 1, -80 * k),
			Size = UDim2.fromOffset(200, 18),
			BackgroundTransparency = 1,
			Font = Type.Label.Font,
			Text = "HOTBAR",
			TextColor3 = Role.TextMuted,
			TextSize = Type.Label.Size,
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = screenFrame,
		})

		local icon = CompanionAbilityIcon.new(screenFrame)
		local def = BrainrotData.Get("Bombardiro Crocodilo")
		icon:SetBrainrot(def)
		icon:SetKey("G")
		local stats = BrainrotData.Stats(def, 5, 2)
		icon:SetStats(stats, def.move)
		icon:Update(0, stats.cooldown, false, false)
		note(string.format("#14 tile: pos %s, readout '%s / %s', dps %.1f",
			tostring(CompanionAbilityIcon.Position), icon.readoutMove.Text, icon.readoutStats.Text,
			(stats.damage or 0) / math.max(stats.cooldown or 1, 0.01)))
	end,
})

return views
