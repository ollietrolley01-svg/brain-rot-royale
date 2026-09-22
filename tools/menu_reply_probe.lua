-- Probe for tools/runtest.ps1 -Probe: the menu remotes' reply path -- Bootstrap's guard() toasts the
-- message it returns (the class behind "a coloured button that does something and says nothing").
--
-- Hard limit: a runtest has no client, so no RemoteFunction can be invoked, and guard() is a local in a
-- Script. So the DECISION is proved by slicing guard()'s text out of Bootstrap's Source and running it
-- against stubs (a profile that exists or not, a budget that allows or not, a handler that succeeds,
-- refuses, is silent or throws), recording every StateSync.Notify. The DOUBLE-TOAST rule is proved on
-- the Source: no `StateSync.Notify` inside any `guard(function ... end)` block, and none left in
-- CrateService (its one was the luck-changed refusal that also returned). Planted every run: the notify
-- cut from the slice must fail the scenarios, and a notify pasted into a guarded block must be counted.
-- What this cannot see: the toast on a real screen -- Oliver's playtest (sell a merged brainrot's last
-- copy from the menu; the red line must appear once).

local ServerScriptService = game:GetService("ServerScriptService")

local checks, failures = 0, 0
local function say(fmt, ...)
	print("[AUDIT menu-reply] " .. string.format(fmt, ...))
end
local function check(ok, text)
	checks += 1
	if not ok then
		failures += 1
	end
	say("%s  %s", ok and "PASS" or "FAIL", text)
end

local bootstrap = ServerScriptService:WaitForChild("Bootstrap")
local source = bootstrap.Source
local crateSource = ServerScriptService:WaitForChild("Modules"):WaitForChild("CrateService").Source

--------------------------------------------------------------------------------
-- 1. guard() sliced out of the Source and run against stubs
--------------------------------------------------------------------------------

local function sliceGuard(src)
	local s = src:find("local function guard(handler)", 1, true)
	if not s then
		return nil, "guard() not found in Bootstrap.Source"
	end
	-- The function is top-level, so the first column-0 `end` after it closes it.
	local _, e = src:find("\r?\nend\r?\n", s)
	if not e then
		return nil, "guard() has no closing end"
	end
	return src:sub(s, e)
end

-- Runs guard(handler)(player, "arg") with stubs; returns what it returned and what it toasted.
local function runGuard(slice, opts)
	local notified = {}
	local env = setmetatable({
		PlayerData = { Get = function() return (not opts.noProfile) and {} or nil end },
		RateLimit = { Take = function() return not opts.limited end },
		refreshLeaderstats = function() end,
		StateSync = { Notify = function(_, message, isError) table.insert(notified, { message = message, isError = isError }) end },
	}, { __index = getfenv(1) })
	local chunk, err = loadstring(slice .. "\nreturn guard", "guard")
	if not chunk then
		return nil, err
	end
	setfenv(chunk, env)
	local guard = chunk()
	local success, message = guard(opts.handler)({ Name = "ProbePlayer" }, "arg")
	return { success = success, message = message, notified = notified }
end

local SCENARIOS = {
	{ "a refusal with a reason", { handler = function() return false, "Sahur is merged (2 stars) - you can't sell your last copy." end },
		{ toasts = 1, text = "Sahur is merged (2 stars) - you can't sell your last copy.", isError = true, success = false } },
	{ "a receipt", { handler = function() return true, "Sold 4 Uncommon brainrots." end },
		{ toasts = 1, text = "Sold 4 Uncommon brainrots.", isError = false, success = true } },
	{ "a silent success (settings saved)", { handler = function() return true end }, { toasts = 0, success = true } },
	{ "a silent refusal", { handler = function() return false, nil end }, { toasts = 0, success = false } },
	{ "a handler that throws", { handler = function() error("boom") end },
		{ toasts = 1, text = "Something went wrong.", isError = true, success = false } },
	{ "over the menu budget", { limited = true, handler = function() return true, "never reached" end }, { toasts = 0, success = false } },
	{ "no profile yet", { noProfile = true, handler = function() return true, "never reached" end },
		{ toasts = 1, text = "Profile still loading.", isError = true, success = false } },
}

local function runScenarios(slice, label)
	local passed, total = 0, #SCENARIOS
	for _, scenario in ipairs(SCENARIOS) do
		local what, opts, want = scenario[1], scenario[2], scenario[3]
		local r, err = runGuard(slice, opts)
		local ok = r ~= nil
			and #r.notified == want.toasts
			and r.success == want.success
			and (want.toasts == 0 or (r.notified[1].message == want.text and r.notified[1].isError == want.isError))
		if ok then
			passed += 1
		end
		if label == "real" then
			check(ok, string.format("guard: %s -> %d toast(s)%s, success %s%s", what, r and #r.notified or -1,
				r and r.notified[1] and string.format(" %q red=%s", r.notified[1].message, tostring(r.notified[1].isError)) or "",
				tostring(r and r.success), err and (" ERROR " .. tostring(err)) or ""))
		end
	end
	return passed, total
end

local slice, sliceErr = sliceGuard(source)
if not slice then
	check(false, "slice: " .. tostring(sliceErr))
else
	runScenarios(slice, "real")
	-- PLANT A: the toast lines cut from the slice -- the scenarios with a message must fail.
	local cut = slice:gsub("pcall%(StateSync%.Notify[^\r\n]*", "")
	local cutPassed, total = runScenarios(cut, "control")
	check(cutPassed < total, string.format("planted: with the notify lines cut, %d of %d scenarios fail (so the checks above can fail)", total - cutPassed, total))
end

--------------------------------------------------------------------------------
-- 2. The double-toast rule, on the Source
--------------------------------------------------------------------------------

-- Every `guard(function` block up to its column-0 `end)`; count StateSync.Notify inside.
local function notifiesInsideGuarded(src)
	local count, blocks, from = 0, 0, 1
	while true do
		local s = src:find("guard(function", from, true)
		if not s then
			break
		end
		local _, e = src:find("\r?\nend%)", s)
		if not e then
			break
		end
		blocks += 1
		local body = src:sub(s, e)
		for _ in body:gmatch("StateSync%.Notify") do
			count += 1
		end
		from = e
	end
	return count, blocks
end

local inside, blocks = notifiesInsideGuarded(source)
check(blocks >= 20, string.format("scan: %d guarded handler blocks found (want the menu's 20+)", blocks))
check(inside == 0, string.format("scan: %d StateSync.Notify call(s) inside guarded handlers (want 0: the reply is toasted once, by guard)", inside))

-- PLANT B: a notify pasted into a guarded block must be counted.
local planted = source:gsub("guard%(function%(player, tier%)", "guard(function(player, tier)\n\tStateSync.Notify(player, \"planted\")", 1)
local plantedCount = notifiesInsideGuarded(planted)
check(plantedCount == inside + 1, string.format("planted: a notify pasted into BuyCrate's handler is counted (%d -> %d)", inside, plantedCount))

local crateNotifies = 0
for _ in crateSource:gmatch("StateSync%.Notify") do
	crateNotifies += 1
end
check(crateNotifies == 0, string.format("CrateService: %d StateSync.Notify call(s) (want 0: the luck-changed refusal is returned, and toasted by the route that asked)", crateNotifies))

say("RESULT %s: %d checks, %d failed. Not seen here (no client): the toast on screen -- Oliver's playtest: sell a merged brainrot's last copy from the menu, the red line appears once.",
	failures == 0 and "PASS" or "FAIL", checks, failures)
pcall(flush)
