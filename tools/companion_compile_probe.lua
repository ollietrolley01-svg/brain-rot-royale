-- Compile check for the companion and brainrot files, for tools/runtest.ps1 -Probe (~20 s).
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/companion_compile_probe.lua
--
-- Edit mode never runs client scripts, so a LocalScript that doesn't compile only shows up in a
-- playtest. This loads every file below with loadstring (which reports syntax errors with a line)
-- and requires the ModuleScripts, so a broken HudClient or CompanionFxClient is caught in seconds.

local targets = {
	{ "ReplicatedStorage", "Shared", "BrainrotModels" },
	{ "ReplicatedStorage", "Shared", "BrainrotData" },
	{ "ReplicatedStorage", "Shared", "CompanionAnimations" },
	{ "ServerScriptService", "Modules", "CompanionService" },
	{ "StarterPlayer", "StarterPlayerScripts", "CompanionFxClient" },
	{ "StarterPlayer", "StarterPlayerScripts", "CompanionAbilityIcon" },
	{ "StarterPlayer", "StarterPlayerScripts", "HudClient" },
	{ "StarterPlayer", "StarterPlayerScripts", "CombatClient" },
}

local failures = 0
for _, path in ipairs(targets) do
	local node = game:GetService(path[1])
	for index = 2, #path do
		node = node and node:FindFirstChild(path[index])
	end
	if not node then
		failures += 1
		print("[PROBE compile] MISSING " .. table.concat(path, "."))
	else
		local fn, err = loadstring(node.Source, node.Name)
		if not fn then
			failures += 1
			print("[PROBE compile] SYNTAX " .. node.Name .. ": " .. tostring(err))
		elseif node:IsA("ModuleScript") and path[1] ~= "StarterPlayer" then
			local ok, result = pcall(require, node)
			print(string.format("[PROBE compile] %s compiles, require %s", node.Name, ok and "ok" or ("FAILED: " .. tostring(result))))
			if not ok then
				failures += 1
			end
		else
			print("[PROBE compile] " .. node.Name .. " compiles")
		end
	end
end
print(string.format("[PROBE compile] == %d files, %d failures", #targets, failures))
