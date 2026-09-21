-- Merge gallery: the real merge confirmation card (StarterPlayerScripts/MergeDialog) at a few
-- rarities and star counts, plus a glyph sheet, captured from Studio's edit viewport.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/merge_gallery.lua -OutDir <folder>
--
-- The card is a ScreenGui, so each view parents one to StarterGui, which Studio draws over the
-- edit viewport, and removes the previous view's. The glyph sheet exists because the merge UI is
-- the first to lean on ★: it shows every non-ASCII character the merge UI and the menu use, in
-- each font that draws them, so a missing glyph shows up as a box instead of being assumed away.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local UiKit = require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("UiKit"))
local MergeDialog = require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("MergeDialog"))

local GUI_NAME = "BRR_MergeGallery"

local function freshGui()
	local old = StarterGui:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = StarterGui
	return gui
end

local function aimAtSky(camera)
	camera.CFrame = CFrame.new(0, 600, 0) * CFrame.Angles(math.rad(10), 0, 0)
end

-- `after` optionally drives the card past its first state: "busy" presses CONFIRM, "refused" and
-- "merged" also answer for the server, the way MenuClient does.
local function dialogView(name, brainrot, level, stars, count, after)
	return {
		name = name,
		settle = 1.5,
		setup = function(_folder, camera)
			aimAtSky(camera)
			-- Hold the merged state on screen for the capture; every other view uses the real delay.
			MergeDialog.CloseAfterSuccess = after == "merged" and 600 or 1.1
			local def = BrainrotData.Get(brainrot)
			assert(def, "no brainrot " .. brainrot)
			local confirmed = false
			local overlay = MergeDialog.Open(freshGui(), {
				def = def,
				level = level,
				stars = stars,
				count = count,
				instant = true,
				onConfirm = function()
					confirmed = true
				end,
			})
			assert(overlay, "MergeDialog.Open refused " .. brainrot)
			if after then
				MergeDialog.Confirm()
				MergeDialog.Confirm()
				assert(confirmed, "CONFIRM didn't reach onConfirm")
			end
			if after == "refused" then
				MergeDialog.Resolve(false, "Finish or cancel your trade before merging.")
			elseif after == "merged" then
				MergeDialog.Resolve(true, string.format("Merged %s to %s!  +%d%% damage and health", def.name,
					BrainrotData.StarText(stars + 1), math.floor((BrainrotData.StarBonus(stars + 1) - 1) * 100 + 0.5)))
			end
			print(string.format("[BRR_Gallery] note %s: card %s, open=%s", name,
				tostring(overlay:FindFirstChildOfClass("Frame").AbsoluteSize), tostring(MergeDialog.IsOpen())))
		end,
	}
end

local views = {
	dialogView("common_0_to_1", "Tung Tung Tung Sahur", 1, 0, 2),
	dialogView("legendary_3_to_4", "Golden Sahur", 7, 3, 5),
	dialogView("secret_4_to_5", "Il Buco Nero Bello", 10, 4, 4),
	dialogView("uncommon_busy", "Pinguino Scivolo", 3, 1, 3, "busy"),
	dialogView("rare_refused", "Fungo Saltarello", 5, 2, 4, "refused"),
	dialogView("epic_merged", "Astronauta Pisolino", 4, 1, 3, "merged"),
	{
		name = "glyphs",
		settle = 1.5,
		setup = function(_folder, camera)
			aimAtSky(camera)
			MergeDialog.Close()
			local gui = freshGui()
			local sheet = UiKit.create("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(620, 250),
				BackgroundColor3 = UiKit.Colors.Background,
				BorderSizePixel = 0,
				Parent = gui,
			}, { UiKit.rounded(12) })
			local fonts = { Enum.Font.GothamBold, Enum.Font.Gotham, Enum.Font.FredokaOne }
			for index, font in ipairs(fonts) do
				UiKit.create("TextLabel", {
					Position = UDim2.fromOffset(20, 16 + (index - 1) * 56),
					Size = UDim2.fromOffset(580, 48),
					BackgroundTransparency = 1,
					Font = font,
					Text = string.format("%s  ★★★☆☆  • — ✓ ×  %s", font.Name, BrainrotData.StarText(2)),
					TextColor3 = Color3.fromRGB(255, 184, 48),
					TextSize = 26,
					TextXAlignment = Enum.TextXAlignment.Left,
					Parent = sheet,
				})
			end
			UiKit.create("TextLabel", {
				Position = UDim2.fromOffset(20, 190),
				Size = UDim2.fromOffset(580, 40),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				RichText = true,
				Text = 'RichText  <font color="#FFB830">★★</font><font color="#FFF4BE">★</font><font color="#464A5C">★★</font>',
				TextColor3 = Color3.new(1, 1, 1),
				TextSize = 26,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = sheet,
			})
		end,
	},
}

return views
