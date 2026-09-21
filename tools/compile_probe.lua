-- Compile check for EVERY script in the place, for tools/runtest.ps1 -Probe (about 20 seconds).
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/compile_probe.lua
--
-- Studio's edit mode runs nothing, so a script that doesn't compile is invisible until a playtest —
-- and a LocalScript that doesn't compile is invisible until someone joins. tools/balance.py and
-- tools/lua_static_check.py catch a lot (block balance, forward references, colon-without-call) but
-- neither is a parser: only the real compiler is.
--
-- This loads every Script, LocalScript and ModuleScript in the game with loadstring, which reports
-- a syntax error with its line, and then requires every ModuleScript, which catches the errors that
-- only happen when a file RUNS: a nil index at the top level, a require cycle, a missing sibling.
-- tools/companion_compile_probe.lua does the same for one feature's files; this is the whole tree,
-- and it's the cheapest thing to run before declaring an area finished.
--
-- The self-test compiles a deliberately broken chunk and requires the counter to report it, so
-- "0 failed" can't mean the check itself is broken.

local ROOTS = {
	{ "ServerScriptService" },
	{ "ReplicatedStorage" },
	{ "StarterPlayer", "StarterPlayerScripts" },
	{ "StarterPlayer", "StarterCharacterScripts" },
	{ "StarterGui" },
	{ "ServerStorage" },
}

local function out(fmt, ...)
	print("[AUDIT compile] " .. string.format(fmt, ...))
end

-- Where a script lives, as a path a person can search for.
local function pathOf(instance)
	local parts = {}
	local node = instance
	while node and node ~= game do
		table.insert(parts, 1, node.Name)
		node = node.Parent
	end
	return table.concat(parts, "/")
end

local syntaxFailures, requireFailures, compiled, required = {}, {}, 0, 0

local function checkSource(script)
	local ok, source = pcall(function()
		return script.Source
	end)
	if not ok or type(source) ~= "string" then
		-- Source is unreadable from a plugin only when the script is protected; nothing to do.
		return
	end
	compiled += 1
	local chunk, err = loadstring(source, pathOf(script))
	if not chunk then
		table.insert(syntaxFailures, string.format("%s: %s", pathOf(script), tostring(err)))
	end
end

for _, path in ipairs(ROOTS) do
	local node = game:FindFirstChild(path[1])
	for index = 2, #path do
		node = node and node:FindFirstChild(path[index])
	end
	if node then
		for _, descendant in ipairs(node:GetDescendants()) do
			if descendant:IsA("LuaSourceContainer") then
				checkSource(descendant)
			end
		end
	end
end

-- Requiring catches what compiling can't: a top-level error, a missing sibling, a cycle.
for _, path in ipairs(ROOTS) do
	local node = game:FindFirstChild(path[1])
	for index = 2, #path do
		node = node and node:FindFirstChild(path[index])
	end
	if node then
		for _, descendant in ipairs(node:GetDescendants()) do
			if descendant:IsA("ModuleScript") then
				required += 1
				local ok, err = pcall(require, descendant)
				if not ok then
					table.insert(requireFailures, string.format("%s: %s", pathOf(descendant), tostring(err)))
				end
			end
		end
	end
	task.wait()
end

-- Self-test: a chunk that cannot compile, and one that errors when it runs.
local brokenChunk = loadstring("local x = = 1", "self-test")
local runner = loadstring("error('planted')", "self-test")
local ranOk = runner and pcall(runner) or false
out("self-test: broken syntax %s, planted runtime error %s -> %s",
	brokenChunk == nil and "rejected" or "ACCEPTED", ranOk and "SWALLOWED" or "caught",
	(brokenChunk == nil and not ranOk) and "PASS" or "FAIL (the counts below prove nothing)")

out("compiled %d scripts, required %d modules", compiled, required)
for _, text in ipairs(syntaxFailures) do
	out("  SYNTAX  %s", text)
end
for _, text in ipairs(requireFailures) do
	out("  REQUIRE %s", text)
end
out("RESULT %s: %d syntax errors, %d modules that wouldn't load",
	(#syntaxFailures == 0 and #requireFailures == 0) and "PASS" or "FAIL", #syntaxFailures, #requireFailures)
pcall(flush)
