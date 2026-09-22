-- Client regression: runs with the real Roblox camera, including first-person
-- and a competing camera writer. Used by build_cursor_test.py, never shipped.
--
-- HARNESS LIMIT, MEASURED (HUD tab, 09-21): this file cannot be executed by runtest.ps1 in either
-- mode, and this is not a bug in the runner. `-Probe` splices the probe's own source directly into
-- a plugin `Script` (see runtest.ps1 ~line 1385: `PROBE_SOURCE` is substituted inside a `pcall`
-- inside a Script's own Source), run in Studio EDIT mode with no Play session -- confirmed by
-- running it: `attempt to index nil with 'Character'` at `Players.LocalPlayer.Character`, because
-- there is no LocalPlayer there at all. The full run path (no `-Probe`) is server-only and its own
-- comment says so directly ("Client scripts never run in Run mode", runtest.ps1:82) -- it only
-- syntax-checks a LocalScript via loadstring, never executes it. This is the same family as the
-- menu tab's LocalScript lesson in COORDINATION.md ("nothing in this harness can run a
-- LocalScript"), just reached from the MouseBehavior/MouseIconEnabled side: this probe needs a
-- live client (a real Players.LocalPlayer, a real UserInputService mouse), and no automated Studio
-- mode this project has gives it one. It is written correctly for a MANUAL Play-test (F5, or
-- Oliver's own client) and kept for that; do not spend another run trying to automate it.
--
-- Checks the INVARIANT MenuCursor.client.lua exists to hold, not a scripted restore:
-- MouseIconEnabled must equal (a menu has the mouse) OR (the mouse isn't locked to the
-- crosshair) -- checked every settled frame, never seeded by this probe. The previous version
-- wrote `Input.MouseIconEnabled = false` as setup before opening the menu: a state nothing in the
-- real game ever produces, since before this fix nothing but MenuCursor ever wrote the property at
-- all. That let the check pass forever without once proving the icon hides during real FPS lock --
-- it only proved the save/restore mechanism restored whatever the probe itself had planted. This
-- version never writes MouseIconEnabled; only MenuCursor's real code does, same as in the shipped
-- game, and the assertion is the live derivation rather than a snapshot equality.
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
local lockEnabled = true

-- Simulate the camera rewriting the lock each frame, even while a menu is up -- the same fight
-- CombatClient's own per-frame writers put up against MenuCursor in the real game.
RunService:BindToRenderStep("CursorProbeCamera", Enum.RenderPriority.Camera.Value + 5, function()
	Input.MouseBehavior = lockEnabled and Enum.MouseBehavior.LockCenter or Enum.MouseBehavior.Default
end)

RunService:BindToRenderStep("CursorProbeObserve", Enum.RenderPriority.Last.Value + 1, function()
	if phase == "" then return end
	checked += 1
	local expectedIcon = modal.Visible or Input.MouseBehavior ~= Enum.MouseBehavior.LockCenter
	if Input.MouseIconEnabled ~= expectedIcon then
		failures += 1
		warn(string.format("[CURSOR] FAIL %s icon=%s expected=%s behavior=%s modal=%s",
			phase, tostring(Input.MouseIconEnabled), tostring(expectedIcon),
			tostring(Input.MouseBehavior), tostring(modal.Visible)))
	end
end)

for _, mode in ipairs({ Enum.CameraMode.LockFirstPerson, Enum.CameraMode.Classic }) do
	player.CameraMode = mode
	for cycle = 1, 3 do
		phase = ""
		player:SetAttribute("MenuOpen", true)
		task.wait(0.1)
		phase = mode.Name .. " open " .. cycle
		task.wait(0.4)
		phase = ""
		player:SetAttribute("MenuOpen", false)
		task.wait(0.1)
		phase = mode.Name .. " closed " .. cycle
		task.wait(0.3)
	end
end

-- Leaving combat while a menu is open, then closing it: the icon must read the NOW-unlocked mouse
-- the instant it settles, not a value carried over from before the menu opened. This is the exact
-- case the old snapshot/restore model got backwards.
phase = ""
player:SetAttribute("MenuOpen", true)
task.wait(0.1)
lockEnabled = false
player:SetAttribute("MenuOpen", false)
task.wait(0.1)
phase = "closed outside combat"
task.wait(0.4)

-- And the reverse, which the old probe never covered at all: entering FPS combat with no menu
-- ever having opened this session. Nothing to restore here -- only the live derivation can pass it.
phase = ""
lockEnabled = true
task.wait(0.1)
phase = "combat lock, no menu ever opened"
task.wait(0.4)

phase = ""
RunService:UnbindFromRenderStep("CursorProbeObserve")
RunService:UnbindFromRenderStep("CursorProbeCamera")
print(string.format("[CURSOR] RESULT %d frames checked, %d failures", checked, failures))
assert(failures == 0, "Menu cursor regression")
