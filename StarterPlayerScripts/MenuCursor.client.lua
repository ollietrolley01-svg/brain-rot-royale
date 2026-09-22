-- MenuOpen is shared by the inventory and main menu. A one-time MouseBehavior write loses to
-- Roblox's camera on the next frame, even in Classic mode when the camera is still zoomed into
-- first person. Keep a modal GUI alive for the whole menu lifetime and reassert the cursor after
-- the camera has updated.
--
-- SOLE OWNER OF MouseIconEnabled (Oliver's #112, "can still see my cursor in FPS"). CombatClient
-- owns MouseBehavior -- LockCenter for FPS combat, Default otherwise -- and never touches the
-- icon; nothing else in the project ever did either, so the icon sat on whatever this script last
-- wrote, forever. The old code SNAPSHOTTED MouseIconEnabled on open and RESTORED that snapshot on
-- close. That is wrong on its face: nothing upstream of the snapshot ever set the property false,
-- so the snapshot's reachable value was always true, and "restore" meant "set it back to true" on
-- every close, in FPS or not. This derives the icon LIVE from the mouse lock instead, so it is
-- correct after every exit path (death, respawn, a vehicle, spectating, a settings change) with no
-- path to enumerate: whatever CombatClient currently has MouseBehavior set to IS the answer, read
-- back rather than guessed.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "BrrMenuCursor"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = -100
gui.Parent = playerGui

-- A visible but transparent one-pixel modal flag. It occupies no menu hit area
-- and never enters gamepad navigation. Existing buttons keep receiving clicks.
local modal = Instance.new("TextButton")
modal.Name = "CursorRelease"
modal.Size = UDim2.fromOffset(1, 1)
modal.BackgroundTransparency = 1
modal.Text = ""
modal.AutoButtonColor = false
modal.Selectable = false
modal.Active = false
modal.Modal = true
modal.Visible = false
modal.Parent = gui

local open = false

-- The invariant this whole script exists to hold: the icon is wanted whenever a menu has the
-- mouse (so it can be seen and clicked with), and otherwise wanted exactly when the mouse ISN'T
-- locked to the crosshair. Locked with no menu open is FPS combat -- the one place a visible OS
-- cursor is a bug, not a convenience.
local function desiredIcon()
	return open or UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter
end

local function reconcileIcon()
	UserInputService.MouseIconEnabled = desiredIcon()
end

local function releaseCursor()
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	reconcileIcon()
end

local function sync()
	local wanted = player:GetAttribute("MenuOpen") == true
	if wanted == open then return end
	open = wanted
	modal.Visible = wanted
	if wanted then
		releaseCursor()
		RunService:BindToRenderStep("BRR_MenuCursor", Enum.RenderPriority.Last.Value, releaseCursor)
	else
		RunService:UnbindFromRenderStep("BRR_MenuCursor")
		-- CombatClient's own MenuOpen listener restores MouseBehavior to whatever the current mode
		-- wants; reconcileIcon reads that back live. If this runs before CombatClient's listener
		-- does (connection order between two LocalScripts is not guaranteed), the MouseBehavior
		-- property-changed listener below catches the correction the moment CombatClient writes it,
		-- so the result is right either way, not just on the order this script happens to see first.
		reconcileIcon()
	end
end

player:GetAttributeChangedSignal("MenuOpen"):Connect(sync)
-- The lock can also change with no menu involved at all: entering or leaving FPS combat, a
-- vehicle, death. The icon has to follow every one of those, not only a menu's open/close.
UserInputService:GetPropertyChangedSignal("MouseBehavior"):Connect(function()
	if not open then
		reconcileIcon()
	end
end)
sync()
reconcileIcon()

script.Destroying:Connect(function()
	RunService:UnbindFromRenderStep("BRR_MenuCursor")
	gui:Destroy()
end)
