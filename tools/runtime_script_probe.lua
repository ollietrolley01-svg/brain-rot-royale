-- Probe for tools/runtest.ps1 -Probe: proves the playtest-checklist trick works. A Script created at
-- runtime from plugin-level code (the Command Bar has the same security, and it's the only way to set
-- a Script's Source), parented to ServerScriptService during Run mode, runs, and runs in the SERVER's
-- context, sharing its module cache rather than getting a separate copy the way plugin/Command Bar
-- `require` does.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/runtime_script_probe.lua
--
-- The marker used is something only the server's own copy of a module has: Bootstrap sets
-- `BattlePassService.OnXp = ProgressionService.OnPassXp` on the modules the server required. A separate
-- copy (this plugin's) has OnXp nil.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local failures = 0
local function expect(label, ok, detail)
	if not ok then
		failures += 1
	end
	print(string.format("[PROBE] %s %s%s", ok and "PASS" or "FAIL", label, detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
end

if not RunService:IsRunning() then
	print("[PROBE] starting run mode")
	RunService:Run()
end

-- Wait for Bootstrap to finish wiring (its progression remotes exist once it has run that far).
local waited = 0
local remotes = nil
while waited < 45 do
	remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if remotes and remotes:FindFirstChild("BuyCellOffer") then
		break
	end
	task.wait(0.5)
	waited += 0.5
end
expect("the server booted and Bootstrap wired progression", remotes ~= nil and remotes:FindFirstChild("BuyCellOffer") ~= nil, string.format("%.1fs", waited))
task.wait(2)

local modules = ServerScriptService:WaitForChild("Modules")
local pluginCopy = require(modules:WaitForChild("BattlePassService"))
expect("a plugin-context require gets its own copy (OnXp is nil there)", pluginCopy.OnXp == nil)

workspace:SetAttribute("BRR_RuntimeRan", nil)
workspace:SetAttribute("BRR_RuntimeSharedOnXp", nil)
workspace:SetAttribute("BRR_RuntimeWrite", nil)

-- 1. A runtime Script runs, and sees the server's copy of BattlePassService.
local first = Instance.new("Script")
first.Name = "BRR_RuntimeProbeA"
first.Source = [==[
	local BattlePassService = require(game:GetService("ServerScriptService").Modules.BattlePassService)
	local ProgressionService = require(game:GetService("ServerScriptService").Modules.ProgressionService)
	workspace:SetAttribute("BRR_RuntimeRan", true)
	workspace:SetAttribute("BRR_RuntimeSharedOnXp", BattlePassService.OnXp ~= nil and BattlePassService.OnXp == ProgressionService.OnPassXp)
	-- A write for the second script to read back.
	ProgressionService.BRR_ProbeMarker = 4242
]==]
first.Parent = ServerScriptService

-- 2. A second runtime Script reads what the first wrote into the shared module table.
task.wait(1.5)
local second = Instance.new("Script")
second.Name = "BRR_RuntimeProbeB"
second.Source = [==[
	local ProgressionService = require(game:GetService("ServerScriptService").Modules.ProgressionService)
	workspace:SetAttribute("BRR_RuntimeWrite", ProgressionService.BRR_ProbeMarker)
	ProgressionService.BRR_ProbeMarker = nil
]==]
second.Parent = ServerScriptService

local deadline = os.clock() + 10
while os.clock() < deadline and workspace:GetAttribute("BRR_RuntimeWrite") == nil do
	task.wait(0.25)
end

expect("a Script created at runtime with Source set actually runs", workspace:GetAttribute("BRR_RuntimeRan") == true)
expect("it runs in the server's context: it sees Bootstrap's OnXp = ProgressionService.OnPassXp", workspace:GetAttribute("BRR_RuntimeSharedOnXp") == true,
	tostring(workspace:GetAttribute("BRR_RuntimeSharedOnXp")))
expect("two runtime Scripts share one module table (a write is read back)", workspace:GetAttribute("BRR_RuntimeWrite") == 4242,
	tostring(workspace:GetAttribute("BRR_RuntimeWrite")))
expect("the plugin's own copy never saw that write", pluginCopy.BRR_ProbeMarker == nil and require(modules.ProgressionService).BRR_ProbeMarker == nil)

first:Destroy()
second:Destroy()
print(string.format("[PROBE] runtime script: %d failed", failures))
