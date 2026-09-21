-- Client regression: runs with the real Roblox camera, including first-person
-- and a competing camera writer. Used by build_cursor_test.py, never shipped.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Input = game:GetService("UserInputService")
local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
character:WaitForChild("HumanoidRootPart")
local modal = player:WaitForChild("PlayerGui"):WaitForChild("BrrMenuCursor"):WaitForChild("CursorRelease")
player.CameraMode = Enum.CameraMode.LockFirstPerson
task.wait(1)
local failures, checked = 0, 0
local phase = ""
local expectedOpen = false
local lockEnabled = true
RunService:BindToRenderStep("CursorProbeCamera", Enum.RenderPriority.Camera.Value + 5, function()
	-- Simulate the camera rewriting the lock each frame, even while a menu is up.
	Input.MouseBehavior = lockEnabled and Enum.MouseBehavior.LockCenter or Enum.MouseBehavior.Default
end)
RunService:BindToRenderStep("CursorProbeObserve", Enum.RenderPriority.Last.Value + 1, function()
	if phase == "" then return end
	checked += 1
	local expectedMouse = (expectedOpen or not lockEnabled) and Enum.MouseBehavior.Default or Enum.MouseBehavior.LockCenter
	if Input.MouseBehavior ~= expectedMouse or modal.Visible ~= expectedOpen or (expectedOpen and not Input.MouseIconEnabled) then
		failures += 1
		warn("[CURSOR] FAIL " .. phase .. " " .. tostring(Input.MouseBehavior) .. " modal=" .. tostring(modal.Visible))
	end
end)
for _, mode in ipairs({ Enum.CameraMode.LockFirstPerson, Enum.CameraMode.Classic }) do
	player.CameraMode = mode
	for cycle = 1, 3 do
		phase = ""
		Input.MouseIconEnabled = false
		expectedOpen = true
		player:SetAttribute("MenuOpen", true)
		task.wait(0.1)
		phase = mode.Name .. " open " .. cycle
		task.wait(0.4)
		phase = ""
		expectedOpen = false
		player:SetAttribute("MenuOpen", false)
		task.wait(0.1)
		if Input.MouseIconEnabled then failures += 1; warn("[CURSOR] previous icon not restored") end
		phase = mode.Name .. " closed " .. cycle
		task.wait(0.3)
	end
end
-- Leaving combat while a menu is open must not restore the old center lock.
phase = ""
expectedOpen = true
player:SetAttribute("MenuOpen", true)
task.wait(0.1)
lockEnabled = false
expectedOpen = false
player:SetAttribute("MenuOpen", false)
task.wait(0.1)
phase = "closed outside combat"
task.wait(0.4)
phase = ""
RunService:UnbindFromRenderStep("CursorProbeObserve")
RunService:UnbindFromRenderStep("CursorProbeCamera")
Input.MouseIconEnabled = true
print(string.format("[CURSOR] RESULT %d frames checked, %d failures", checked, failures))
assert(failures == 0, "Menu cursor regression")
