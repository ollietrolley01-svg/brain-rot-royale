-- MenuOpen is shared by the inventory and main menu. A one-time MouseBehavior
-- write loses to Roblox's camera on the next frame, even in Classic mode when
-- the camera is still zoomed into first person. Keep a modal GUI alive for the
-- whole menu lifetime and apply the cursor after the camera has updated.
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
local previousIcon = true
local function releaseCursor()
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

local function sync()
	local wanted = player:GetAttribute("MenuOpen") == true
	if wanted == open then return end
	open = wanted
	modal.Visible = wanted
	if wanted then
		previousIcon = UserInputService.MouseIconEnabled
		releaseCursor()
		RunService:BindToRenderStep("BRR_MenuCursor", Enum.RenderPriority.Last.Value, releaseCursor)
	else
		RunService:UnbindFromRenderStep("BRR_MenuCursor")
		UserInputService.MouseIconEnabled = previousIcon
		-- CombatClient and Roblox's camera restore the correct current mode.
		-- Never restore a stale lock captured before death, spectating or a vehicle.
	end
end

player:GetAttributeChangedSignal("MenuOpen"):Connect(sync)
sync()

script.Destroying:Connect(function()
	RunService:UnbindFromRenderStep("BRR_MenuCursor")
	if open then UserInputService.MouseIconEnabled = previousIcon end
	gui:Destroy()
end)
