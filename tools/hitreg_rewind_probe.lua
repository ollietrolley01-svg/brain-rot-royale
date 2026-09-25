-- #97 hit registration, the live half: what the rewind actually does with a real ping.
--
-- tools/hitreg_rewind_check.py proves the rewind's GEOMETRY with ping as a parameter. This measures
-- the one input that check cannot: Player:GetNetworkPing() in a real session, and what the rewind made
-- of it shot by shot. It changes nothing in the game; it only listens (LagCompensation.Observer).
--
-- HOW TO RUN (a real server is needed: runtest's edit mode has no Player, so no ping):
--   1. Studio > Test > "Start" with 1 player (Clients and Servers), or a live test server.
--   2. For a ping sweep: File > Studio Settings > Network > Incoming Replication Lag = 0.05, 0.10,
--      0.15, 0.25 in turn (seconds). Note whether GetNetworkPing reports it: if it does not, the
--      simulated lag is invisible to the rewind and only a real remote connection can test it.
--   3. BEFORE pressing Play, put this in a **Script in ServerScriptService** (not the command bar). A
--      ModuleScript's return value is per environment: the command bar's require() gets its own fresh
--      LagCompensation, so an Observer set there never hears a shot and the probe would print nothing
--      (Jacob's #97 proof, section 5). A Script shares the game's module cache. Delete it afterwards.
--      Start a match with a bot or a second player, and shoot at someone STRAFING. Every rewound shot
--      prints one line; the probe stops itself after 200 shots, or run `_G.HitRegProbeStop()` from
--      the server command bar (that only reads _G, which IS shared).
--
-- EACH LINE:
--   ping      the server's reading of the shooter (seconds, round trip)
--   rewound   how far back the victims were put: ping + LagCompensation.InterpolationDelay (read
--             separately, so expect small differences). A shot ruled on the present (ping 0, or over
--             the 0.2 s cap) is not rewound and prints nothing
--   struck    the part name the shot resolved to (Head must appear for head shots: a rewind that
--             reports only torsos has lost headshots, see HITREG_DESIGN.md "THE TRAP")
--   moved     how far the struck victim's root has moved between the rewound instant and now: the
--             distance the rewind made up. Past ~1 stud this is a shot the old code threw away.
--   left      the rewind still LEFT OUT (#97 F1): the instant in the victim's history when the ray passed
--             closest to their root, compared with where the rewind put them. Positive = the rewind
--             should go further back. One shot is noise (the shooter's own aim error); the SUMMARY
--             median over many shots at a strafing target is the interpolation delay still missing.
--             Tune LagCompensation.InterpolationDelay by that median.
-- The summary at the end gives the ping distribution and how many hits needed the rewind.
--
-- WHAT A PASS LOOKS LIKE: pings match the simulated lag (or real ping); rewound == ping + delay; no
-- lines at all once the lag is past 0.2 s; strafing targets are hit with `moved` well over a stud;
-- Head appears; the `left` median is within about +-0.02 s of 0.
-- "wired" prints on the first shot the game's own CombatService rewinds. No "wired" line after firing
-- with a ping means the probe is not sharing the game's LagCompensation (see step 3), NOT a 0 ms result.

local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")
local Modules = ServerScriptService:WaitForChild("Modules")
local LagCompensation = require(Modules:WaitForChild("LagCompensation"))
local Combatants = require(Modules:WaitForChild("Combatants"))

local function out(fmt, ...)
	print((_G.BRR_PROBE_PREFIX or "[HITREG] ") .. string.format(fmt, ...))
end

local LIMIT = 200
local shots, hits, needed, heads = 0, 0, 0, 0
local pings = {}
local lefts = {}

-- The closest point of the ray to `point`, as a distance.
local function rayDistance(point, origin, vector)
	local t = math.clamp((point - origin):Dot(vector) / vector:Dot(vector), 0, 1)
	return (origin + vector * t - point).Magnitude
end

-- How much further back than `at` the victim stood closest to the ray (seconds; negative = the rewind
-- went too far). Searched over the ring in 5 ms steps.
local function leftOver(character, info)
	local best, bestT = math.huge, nil
	for t = info.now - 0.33, info.now, 0.005 do
		local root = LagCompensation.RootAt(character, t, info.now)
		if root then
			local d = rayDistance(root.Position, info.origin, info.vector)
			if d < best then
				best, bestT = d, t
			end
		end
	end
	return bestT and (info.at - bestT) or nil
end

-- The shooter isn't passed to the observer (it is only told about the ray), so the nearest player to
-- the ray's origin is taken as the shooter: their head is where every player shot starts.
local function shooterAt(origin)
	local best, bestDistance = nil, 4
	for _, player in ipairs(Players:GetPlayers()) do
		local head = player.Character and player.Character:FindFirstChild("Head")
		if head and (head.Position - origin).Magnitude < bestDistance then
			best, bestDistance = player, (head.Position - origin).Magnitude
		end
	end
	return best
end

local function stop()
	LagCompensation.Observer = nil
	table.sort(pings)
	local function pct(p)
		return #pings > 0 and pings[math.max(1, math.ceil(#pings * p))] or 0
	end
	out("SUMMARY %d rewound shots, %d struck a combatant, %d of those needed the rewind (victim moved > 1 stud), %d Head", shots, hits, needed, heads)
	out("SUMMARY ping p10 %.3f  p50 %.3f  p90 %.3f  max %.3f s (%d readings)", pct(0.1), pct(0.5), pct(0.9), pings[#pings] or 0, #pings)
	table.sort(lefts)
	if #lefts > 0 then
		out("SUMMARY left over p25 %.3f  MEDIAN %.3f  p75 %.3f s over %d hits (InterpolationDelay is %.3f; add the median to it)",
			lefts[math.max(1, math.ceil(#lefts * 0.25))], lefts[math.max(1, math.ceil(#lefts * 0.5))],
			lefts[math.max(1, math.ceil(#lefts * 0.75))], #lefts, LagCompensation.InterpolationDelay)
	end
	if #pings == 0 then
		out("SUMMARY ping unavailable: no shot was rewound (ping 0, over the cap, no player fired, or the probe was run from the command bar) -- NOT a 0 ms result")
	end
end
_G.HitRegProbeStop = stop

LagCompensation.Observer = function(info)
	shots += 1
	if shots == 1 then
		out("wired: the game's own LagCompensation reported a rewound shot")
	end
	local player = shooterAt(info.origin)
	local ping = player and player:GetNetworkPing() or nil
	if ping then
		table.insert(pings, ping)
	end
	local result = info.result
	local struck, moved, left = "-", nil, nil
	if result then
		struck = result.Instance.Name
		local character = result.Instance:FindFirstAncestorOfClass("Model")
		if character and Combatants.FromCharacter(character) then
			hits += 1
			if struck == "Head" then
				heads += 1
			end
			local past = LagCompensation.RootAt(character, info.at, info.now)
			local root = character:FindFirstChild("HumanoidRootPart")
			if past and root then
				moved = (root.Position - past.Position).Magnitude
				if moved > 1 then
					needed += 1
				end
			end
			left = leftOver(character, info)
			if left then
				table.insert(lefts, left)
			end
		end
	end
	out("shot %3d  shooter %-14s ping %s  rewound %.3f  struck %-16s moved %s  left %s",
		shots, player and player.Name or "?", ping and string.format("%.3f", ping) or "unavailable",
		info.now - info.at, struck, moved and string.format("%.2f", moved) or "-", left and string.format("%+.3f", left) or "-")
	if shots >= LIMIT then
		stop()
	end
end

out("listening: shoot at a strafing target; %d shots, or _G.HitRegProbeStop()", LIMIT)
