-- Isolated Studio Play regression; never included in the published game.
local Players = game:GetService("Players")
local Shared = game.ReplicatedStorage.Shared
local Remotes = require(Shared.Remotes)
local WeaponData = require(Shared.WeaponData)
local Pack = require(Shared.ArsenalExpansion)
local modules = script.Parent.Modules
local Weapons = require(modules.WeaponService)
local Combat = require(modules.CombatService)
local Range = require(modules.RangeService)
local probe = Remotes.Function("RangeProbe")
Remotes.Function("GetSettings").OnServerInvoke = function() return {} end
Remotes.Event("SetAiming").OnServerEvent:Connect(Combat.SetAiming)
Remotes.Event("ReloadWeapon").OnServerEvent:Connect(Weapons.Reload)
local player = Players:GetPlayers()[1] or Players.PlayerAdded:Wait()
local character = player.Character or player.CharacterAdded:Wait()
local root = character:WaitForChild("HumanoidRootPart")
local head = character:WaitForChild("Head")
root.Anchored = true
Range.SetArea(root.Position, 100)
local checked = 0
local function check(ok, msg)
 checked += 1
 assert(ok, "[RANGE] FAIL " .. msg)
end
local shots, hits, ends = 0, 0, {}
local broadcast, confirm = Combat.BroadcastShot, Combat.ConfirmHit
Combat.BroadcastShot = function(...)
 shots += 1
 local args = {...}; ends = args[3]
 return broadcast(...)
end
Combat.ConfirmHit = function(...)
 hits += 1
 return confirm(...)
end
local target = Instance.new("Part")
target.Name = "PracticeTarget"
target.Anchored = true
target.Size = Vector3.new(40, 40, 1)
target.Position = head.Position + Vector3.new(0, 0, -50)
target.Color = Color3.fromRGB(230, 90, 65)
target.Parent = workspace
game:GetService("CollectionService"):AddTag(target, "PracticeDummy")
local bystander = Instance.new("Model")
bystander.Name = "NonTargetBystander"
local body = Instance.new("Part")
body.Name = "HumanoidRootPart"; body.Anchored = true
body.Size = Vector3.new(10, 10, 1)
body.Position = head.Position + Vector3.new(0, 0, -20)
body.Parent = bystander
local hum = Instance.new("Humanoid"); hum.Parent = bystander
bystander.Parent = workspace
task.wait(4) -- allow the real CombatClient and probe to bind their listeners
check(probe:InvokeClient(player, "ready"), "client ready")
for _, id in ipairs(Pack.Order) do
 -- Avatar appearance loading can replace the original Head instance.
 head = character:WaitForChild("Head")
 local def = WeaponData.Get(id)
 check(Range.Give(player, id), id .. " rack pickup")
 task.wait(0.6)
 local loadout = Weapons.Get(player)
 local _, slot = Weapons.GetEquipped(player)
 check(probe:InvokeClient(player, "entered", id), id .. " first person/viewmodel")
 Remotes.Event("MatchChanged"):FireClient(player, {state = "Waiting"})
 check(probe:InvokeClient(player, "entered", id), id .. " lobby state preserves range")
 local before = slot.mag
 loadout.lastShotAt = -100
 Range.Fire(player, head.Position)
 check(slot.mag == before, id .. " rejects zero direction (head current=" .. tostring(head == character:FindFirstChild("Head")) .. ", mag=" .. slot.mag .. ", before=" .. before .. ")")
 Range.Fire(player, Vector3.new(0/0, 1, 2))
 check(slot.mag == before, id .. " rejects NaN")
 local priorShots, priorHits = shots, hits
 Range.Fire(player, target.Position)
 check(slot.mag == before - 1 and shots == priorShots + 1, id .. " accepted shot/ammo/event")
 check(#ends == (def.pellets or 1), id .. " pellet tracers")
 check(hits - priorHits == (def.pellets or 1), id .. " every pellet reaches target")
 Range.Fire(player, target.Position)
 check(slot.mag == before - 1 and shots == priorShots + 1, id .. " fire-rate guard")
 loadout.lastShotAt = -100
 Weapons.Reload(player)
 check(loadout.reloading, id .. " reload begins")
 Range.Fire(player, target.Position)
 check(slot.mag == before - 1 and shots == priorShots + 1, id .. " blocks fire while reloading")
 -- Cancel this test reload with a fresh rack loadout, then test misses.
 check(Range.Give(player, id), id .. " replace during reload")
 task.wait(0.6)
 loadout = Weapons.Get(player)
 _, slot = Weapons.GetEquipped(player)
 loadout.lastShotAt = -100
 Range.Fire(player, head.Position + Vector3.new(0, 100, 0))
 check(shots == priorShots + 2 and #ends == (def.pellets or 1), id .. " miss still broadcasts")
 loadout.lastShotAt = -100; slot.mag = 0
 Range.Fire(player, target.Position)
 check(shots == priorShots + 2, id .. " empty magazine guard")
 check(hum.Health == 100, id .. " cannot damage bystanders")
end
Range.Stop(player)
check(probe:InvokeClient(player, "stopped"), "leaving range restores lobby camera")
check(Weapons.Get(player) == nil and character:FindFirstChild("HeldGun") == nil, "range cleanup")
check(Range.Give(player, "PawnshopNine"), "final test pickup")
task.wait(0.6)
local loadout = Weapons.Get(player)
local _, slot = Weapons.GetEquipped(player)
loadout.lastShotAt = -100
local ammo, count = slot.mag, shots
Combat.SetEnabled(true)
Range.Fire(player, target.Position)
check(slot.mag == ammo and shots == count, "match closes range")
Combat.SetEnabled(false)
Range.Stop(player)
Range.SetArea(root.Position + Vector3.new(1000, 0, 0), 10)
check(not Range.Give(player, "PawnshopNine"), "outside area cannot take weapon")
Combat.BroadcastShot, Combat.ConfirmHit = broadcast, confirm
print(string.format("[RANGE] RESULT %d checks, 0 failures; %d accepted shots", checked, shots))
probe:InvokeClient(player, "done", shots)
