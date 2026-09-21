-- Companion ability tile gallery: the HUD tile (StarterPlayerScripts/CompanionAbilityIcon) in every
-- state, captured over the edit viewport.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/companion_icon_gallery.lua -OutDir <folder> -Hold 1
--
-- Left to right: ready, just used (10%), 35%, 60%, 90% recharged, downed, and a long key name.
-- A second view shows it at its real place beside a stand-in companion panel and health frame.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local scripts = StarterPlayer:WaitForChild("StarterPlayerScripts")
local CompanionAbilityIcon = require(scripts:WaitForChild("CompanionAbilityIcon"))

local GUI_NAME = "BRR_IconGallery"

local function freshGui()
	local old = StarterGui:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.IgnoreGuiInset = true
	gui.Parent = StarterGui
	return gui
end

local function aimAtSky(camera)
	camera.CFrame = CFrame.new(0, 600, 0) * CFrame.Angles(math.rad(10), 0, 0)
end

local STATES = {
	{ remaining = 0, key = "G" },
	{ remaining = 3.6, key = "G" },
	{ remaining = 2.6, key = "G" },
	{ remaining = 1.6, key = "G" },
	{ remaining = 0.4, key = "G" },
	{ remaining = 0, key = "G", downed = true },
	{ remaining = 0, key = "LShift" },
}

return {
	{
		name = "icon_states",
		settle = 1.5,
		setup = function(_, camera)
			aimAtSky(camera)
			local gui = freshGui()
			local defs = { "Golden Sahur", "Fenice Pixelata", "Frigo Camelo", "Il Buco Nero Bello", "Tung Tung Tung Sahur", "Kraken Caramello", "Nonna Nebulosa" }
			for index, state in ipairs(STATES) do
				local icon = CompanionAbilityIcon.new(gui)
				icon.frame.Position = UDim2.new(0.5, (index - 4) * 110 - 36, 0.5, -36)
				icon:SetKey(state.key)
				icon:SetBrainrot(BrainrotData.Get(defs[index]) or BrainrotData.Types[index])
				icon.ready = state.remaining <= 0
				icon:Update(state.remaining, 4, state.downed, false)
				icon.scale.Scale = 1
			end
			print("[BRR_Gallery] note icon states drawn: " .. #STATES)
		end,
	},
	{
		name = "icon_in_place",
		settle = 1.5,
		setup = function(_, camera)
			aimAtSky(camera)
			local gui = freshGui()
			-- Stand-ins for the frames the tile sits beside, at HudClient's real positions and sizes.
			for _, box in ipairs({
				{ UDim2.new(0, 16, 1, -96), UDim2.fromOffset(280, 80), "health" },
				{ UDim2.new(0, 16, 1, -166), UDim2.fromOffset(300, 62), "companion panel" },
				{ UDim2.new(0, 16, 1, -202), UDim2.fromOffset(150, 28), "speed pill" },
			}) do
				local frame = Instance.new("TextLabel")
				frame.Position = box[1]
				frame.Size = box[2]
				frame.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
				frame.BackgroundTransparency = 0.15
				frame.TextColor3 = Color3.fromRGB(146, 152, 170)
				frame.Text = box[3]
				frame.Parent = gui
			end
			local icon = CompanionAbilityIcon.new(gui)
			icon:SetKey("G")
			icon:SetBrainrot(BrainrotData.Get("Drago Arcobaleno") or BrainrotData.Types[1])
			icon.ready = false
			icon:Update(1.2, 4, false, false)
			icon.scale.Scale = 1
			print("[BRR_Gallery] note icon at " .. tostring(icon.frame.AbsolutePosition) .. " size " .. tostring(icon.frame.AbsoluteSize))
		end,
	},
}
