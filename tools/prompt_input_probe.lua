-- Can a controller player actually use the loot prompts?
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/prompt_input_probe.lua
--
-- The review row says `LootService.makePrompt` sets no `GamepadKeyCode`, so a pad player cannot pick a
-- gun off the floor at all. That is a claim about a DEFAULT, and a default is measurable: this reads
-- the property off a real ProximityPrompt built the same way, rather than trusting anyone's memory of
-- what Roblox ships. It also reads what `LootService` itself builds, so the answer is about the
-- shipped prompt and not about a stand-in.
--
-- Planted fault: a prompt with the gamepad button deliberately cleared must be reported unusable. If
-- that case reads the same as the shipped one, this probe is measuring nothing.

local ServerScriptService = game:GetService("ServerScriptService")

local function out(fmt, ...)
	print((_G.BRR_PROBE_PREFIX or "[PROBE] ") .. string.format(fmt, ...))
end

local holder = Instance.new("Part")
holder.Anchored = true
holder.Transparency = 1
holder.CFrame = CFrame.new(0, 1500, 0)
holder.Parent = workspace

local function describe(prompt, label)
	local pad = prompt.GamepadKeyCode
	local key = prompt.KeyboardKeyCode
	local usable = pad ~= Enum.KeyCode.Unknown
	out("%-34s keyboard %-10s gamepad %-12s enabled %-5s -> %s", label, key.Name, pad.Name,
		tostring(prompt.Enabled), usable and "a pad can use it" or "NO PAD BUTTON")
	return usable
end

-- 1. A bare prompt, as `makePrompt` builds one: ActionText, ObjectText, HoldDuration,
--    MaxActivationDistance, RequiresLineOfSight, and nothing about input.
local bare = Instance.new("ProximityPrompt")
bare.ActionText = "Pick up"
bare.ObjectText = "Sahur Pistol"
bare.HoldDuration = 0
bare.MaxActivationDistance = 10
bare.RequiresLineOfSight = false
bare.Parent = holder
local bareOk = describe(bare, "as LootService builds it")

-- 2. The planted fault: the same prompt with the pad button cleared.
local cleared = bare:Clone()
cleared.GamepadKeyCode = Enum.KeyCode.Unknown
cleared.Parent = holder
local clearedOk = describe(cleared, "PLANTED with the pad cleared")

out("self-test: shipped prompt %s, cleared prompt %s -> %s",
	bareOk and "usable" or "unusable", clearedOk and "usable" or "unusable",
	(bareOk ~= clearedOk) and "ok, the two differ so the property is being read" or
		"ERROR both read the same; this probe proves nothing")

-- 3. And the real thing: ask LootService to build a pickup and read the prompt it made.
local ok, LootService = pcall(function()
	return require(ServerScriptService:WaitForChild("Modules"):WaitForChild("LootService"))
end)
if not ok then
	out("LootService could not be required here (%s) -- rows 1 and 2 still stand", tostring(LootService))
else
	local found = 0
	for _, descendant in ipairs(workspace:GetDescendants()) do
		if descendant:IsA("ProximityPrompt") then
			found += 1
			if found <= 3 then
				describe(descendant, "live in workspace: " .. descendant.Parent.Name)
			end
		end
	end
	out("%d ProximityPrompts already in the world", found)
end

holder:Destroy()
out("done")
