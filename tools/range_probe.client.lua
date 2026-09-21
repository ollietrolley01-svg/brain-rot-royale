local player = game.Players.LocalPlayer
local Remotes = require(game.ReplicatedStorage.Shared.Remotes)
local observed = 0
Remotes.Event("ShotFired").OnClientEvent:Connect(function(shooter, origin, ends)
 if shooter == player then
  observed += 1
  assert(typeof(origin) == "Vector3" and #ends > 0, "range shot missing trace")
 end
end)
Remotes.Function("RangeProbe").OnClientInvoke = function(phase, value)
 if phase == "ready" then return true end
 if phase == "entered" then
  task.wait(0.1)
  assert(player.CameraMode == Enum.CameraMode.LockFirstPerson, "[RANGE CLIENT] not in first person: " .. value)
  assert(workspace.CurrentCamera:FindFirstChild("BRR_Viewmodel"), "[RANGE CLIENT] missing viewmodel: " .. value)
  -- Exercise real CombatClient menu camera wiring as well as the cursor release.
  player:SetAttribute("MenuOpen", true)
  task.wait(0.1)
  assert(game:GetService("UserInputService").MouseBehavior == Enum.MouseBehavior.Default, "[RANGE CLIENT] menu cursor locked")
  player:SetAttribute("MenuOpen", false)
  task.wait(0.1)
  assert(player.CameraMode == Enum.CameraMode.LockFirstPerson, "[RANGE CLIENT] menu close lost range camera")
 elseif phase == "stopped" then
  task.wait(0.2)
  assert(player.CameraMode == Enum.CameraMode.Classic, "[RANGE CLIENT] still in range camera")
 elseif phase == "done" then
  task.wait(0.2)
  assert(observed == value, "[RANGE CLIENT] lost shot broadcasts")
  print("[RANGE CLIENT] RESULT camera/menu transitions passed; " .. observed .. " shot events received")
 end
 return true
end
