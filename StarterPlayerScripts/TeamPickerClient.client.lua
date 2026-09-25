-- The team picker's wiring: the remotes, the keys, the gamepad, the cursor and the screen size. The
-- drawing is TeamPickerScreen, the placement TeamPickerLayout, and every rule the server's TeamPicker.
--
-- Shown only while the server says the window is open AND the match is a team mode in its Loading
-- state; the battle royale never shows it (TeamPickerRules.ShowsFor), and anything else hides it.
--
-- Inputs:
--   mouse / touch  tap a card, or AUTO-ASSIGN
--   keyboard       1 and 2 pick a side, 3 is AUTO (arrow keys move the focus when it is on)
--   gamepad        the focus starts on your side (else AUTO); d-pad / stick moves it, A confirms the
--                  focused choice, B confirms AUTO; L1 / R1 jump straight to a side
-- While it is up it holds the cursor (MenuOpenClaims), which also stands the stamina bar down, and sets
-- the TeamPickerOpen attribute so MenuClient tucks the MENU stack away.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameModes = require(Shared:WaitForChild("GameModes"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local TeamPickerRules = require(Shared:WaitForChild("TeamPickerRules"))

local TeamPickerScreen = require(script.Parent:WaitForChild("TeamPickerScreen"))
local TeamPickerLayout = require(script.Parent:WaitForChild("TeamPickerLayout"))
local MenuOpenClaims = require(script.Parent:WaitForChild("MenuOpenClaims"))
local PhoneLayout = require(script.Parent:WaitForChild("PhoneLayout"))

local changed = Remotes.Event("TeamPickerChanged")
local matchChanged = Remotes.Event("MatchChanged")
local pickTeam = Remotes.Event("PickTeam")

local okSfx, Sfx = pcall(function()
	return require(script.Parent:WaitForChild("Sfx"))
end)

local gui = Instance.new("ScreenGui")
gui.Name = "TeamPickerUi"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
-- Level with the pre-match vote and drop screens (VoteDropClient): it is one of them.
gui.DisplayOrder = 30
gui.Parent = playerGui

-- The device's safe area, read off a ScreenGui that keeps to it (notches, rounded corners, the home
-- bar). Nothing is drawn in it.
local safeProbe = Instance.new("ScreenGui")
safeProbe.Name = "TeamPickerSafeArea"
safeProbe.ResetOnSpawn = false
safeProbe.IgnoreGuiInset = true
pcall(function()
	safeProbe.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
end)
safeProbe.Parent = playerGui
local safeFrame = Instance.new("Frame")
safeFrame.Name = "Area"
safeFrame.BackgroundTransparency = 1
safeFrame.Size = UDim2.fromScale(1, 1)
safeFrame.Parent = safeProbe

local screen = TeamPickerScreen.new(gui)
local snapshot = nil
local matchState = nil
local release = nil
local opening = false

local function inputKind()
	local last = UserInputService:GetLastInputType()
	local name = last and last.Name or ""
	if string.find(name, "Gamepad") then
		return "gamepad"
	end
	if last == Enum.UserInputType.Touch or (UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled) then
		return "touch"
	end
	return "keyboard"
end

local function viewport()
	local camera = workspace.CurrentCamera
	return camera and camera.ViewportSize or Vector2.new(1920, 1080)
end

-- The chat window's rect, when TextChatService has drawn one.
local function chatRect()
	local ok, rect = pcall(function()
		local config = game:GetService("TextChatService"):FindFirstChildOfClass("ChatWindowConfiguration")
		if not (config and config.Enabled) then
			return nil
		end
		local p, s = config.AbsolutePosition, config.AbsoluteSize
		if s.X < 1 or s.Y < 1 then
			return nil
		end
		return TeamPickerLayout.rect(p.X, p.Y, s.X, s.Y)
	end)
	return ok and rect or nil
end

local function safeRect(vp)
	local p, s = safeFrame.AbsolutePosition, safeFrame.AbsoluteSize
	if typeof(p) == "Vector2" and typeof(s) == "Vector2" and s.X > 100 and s.Y > 100 then
		return TeamPickerLayout.rect(p.X, p.Y, s.X, s.Y)
	end
	return TeamPickerLayout.rect(0, 0, vp.X, vp.Y)
end

local function layout()
	local vp = viewport()
	local inset = GuiService:GetGuiInset().Y
	local touch = PhoneLayout.Active(vp)
	local ctx = {
		inset = inset,
		touch = touch,
		phone = touch and PhoneLayout.Rects(vp) or nil,
		chat = chatRect(),
		safe = safeRect(vp),
		measured = TeamPickerLayout.Measure(playerGui, gui, inset),
	}
	screen:Layout(TeamPickerLayout.Compute(vp, ctx))
end

local function isOpen()
	if not (snapshot and snapshot.open) then
		return false
	end
	if not TeamPickerRules.ShowsFor(GameModes.Get(snapshot.mode)) then
		return false
	end
	-- The match broadcast has the last word: only in a team mode's Loading.
	if matchState and (matchState.state ~= "Loading" or matchState.mode ~= snapshot.mode) then
		return false
	end
	return true
end

local function focus()
	if inputKind() == "gamepad" then
		pcall(function()
			GuiService.SelectedObject = screen:FocusTarget()
		end)
	end
end

local function sync()
	if isOpen() then
		if not screen.shown then
			if opening then
				return
			end
			opening = true
			if not release then
				release = MenuOpenClaims.Claim("TeamPicker")
			end
			player:SetAttribute("TeamPickerOpen", true)
			-- One frame for the stamina bar and the MENU stack to stand down, then measure what is left.
			task.spawn(function()
				task.wait()
				opening = false
				if not isOpen() then
					sync()
					return
				end
				layout()
				screen:SetInput(inputKind())
				screen:Render(snapshot)
				screen:Show()
				focus()
			end)
		else
			screen:Render(snapshot)
		end
	elseif screen.shown or release then
		screen:Hide()
		player:SetAttribute("TeamPickerOpen", nil)
		pcall(function()
			if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(gui) then
				GuiService.SelectedObject = nil
			end
		end)
		if release then
			release()
			release = nil
		end
	end
end

screen.OnPick = function(team)
	if okSfx and Sfx and Sfx.Play then
		pcall(Sfx.Play, "UiClick", 0.08)
	end
	pickTeam:FireServer(team)
end

changed.OnClientEvent:Connect(function(snap)
	if type(snap) ~= "table" then
		return
	end
	snapshot = snap
	sync()
end)

matchChanged.OnClientEvent:Connect(function(state)
	if type(state) ~= "table" then
		return
	end
	matchState = state
	sync()
	-- The seconds tick on the match broadcast; the snapshot only comes when a pick changes something.
	if screen.shown and state.teamSelect and snapshot then
		screen:Countdown(state.countdown or 0, snapshot.seconds or 12)
	end
end)

local KEYS = {
	[Enum.KeyCode.One] = 1, [Enum.KeyCode.KeypadOne] = 1,
	[Enum.KeyCode.Two] = 2, [Enum.KeyCode.KeypadTwo] = 2,
	[Enum.KeyCode.Three] = 0, [Enum.KeyCode.KeypadThree] = 0,
	[Enum.KeyCode.ButtonL1] = 1, [Enum.KeyCode.ButtonR1] = 2,
	[Enum.KeyCode.ButtonB] = 0,
}

UserInputService.InputBegan:Connect(function(input, processed)
	if not screen.shown then
		return
	end
	local team = KEYS[input.KeyCode]
	-- A text box has the number keys (chat); the gamepad's own buttons still count.
	if team == nil or (processed and input.UserInputType == Enum.UserInputType.Keyboard) then
		return
	end
	screen:Choose(team)
	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		focus()
	end
end)

UserInputService.LastInputTypeChanged:Connect(function()
	if screen.shown then
		local kind = inputKind()
		if kind ~= screen.input then
			screen:SetInput(kind)
			focus()
		end
	end
end)

local function watchCamera()
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			if screen.shown then
				layout()
				screen:Show()
				focus()
			end
		end)
	end
end
watchCamera()
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)
