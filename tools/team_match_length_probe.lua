-- Task 18: how long a real team match lasts, and how it ends. One Team Deathmatch, then one Objective
-- Capture, played out by the real server scripts (Bootstrap, MatchService, GameMode, BotService) with the
-- bot fill fighting for real. No player joins, so no LobbyService UI is involved.
--
-- Run: python tools/linux/studio.py runtest -Probe tools/team_match_length_probe.lua -WaitSeconds 2100
--      (Windows: powershell tools/runtest.ps1 -Probe tools/team_match_length_probe.lua -WaitSeconds 2100)
-- Read: python tools/team_match_length_check.py . --log <the captured log>
--
-- The probe runs in the plugin, and the game runs in its own VM, so it cannot reach the game's modules.
-- Before pressing Run it edits three sources IN THE STUDIO SESSION ONLY (the snapshot, never the repo):
--   MatchConfig   MinPlayers 1 -> 0, so a bots-only lobby starts a match (as storm_lobby_probe does)
--   VoteService   Resolve answers TeamDeathmatch for the first match and KingOfTheHill for the second
--   GameMode      prints "[TML] tick" every 30 s of a team match and "[TML] end" when one finishes,
--                 with the scores, the target and the seconds left, so the end reads as score or time
--   MatchService  concludeIfOver's respawn-mode exit for "no real player alive" is switched off: without a
--                 player it ended every team match the moment it started. Nothing else in it is touched.
-- The limits, the bots and everything they do are the shipped ones. Each patch must match exactly once;
-- a patch that no longer matches fails the probe instead of measuring an unpatched game.

local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LogService = game:GetService("LogService")

local function say(fmt, ...)
	print(string.format("[TML-probe] " .. fmt, ...))
end

local function patch(script, old, new)
	local src = script.Source
	local at = string.find(src, old, 1, true)
	if not at or string.find(src, old, at + 1, true) then
		error("patch anchor not found exactly once in " .. script:GetFullName() .. ": " .. old)
	end
	script.Source = string.sub(src, 1, at - 1) .. new .. string.sub(src, at + #old)
end

local Modules = ServerScriptService:WaitForChild("Modules")
local Shared = ReplicatedStorage:WaitForChild("Shared")

if RunService:IsRunning() then
	error("the probe must patch before Run; the session was already running")
end

patch(Shared:WaitForChild("MatchConfig"), "MatchConfig.MinPlayers = 1\n", "MatchConfig.MinPlayers = 0\n")

patch(Modules:WaitForChild("VoteService"), "function VoteService.Open()\n",
	"local TML_SEQ, TML_N = { \"TeamDeathmatch\", \"KingOfTheHill\" }, 0\nfunction VoteService.Open()\n\tTML_N += 1\n")
patch(Modules:WaitForChild("VoteService"), "\treturn resolved.mapId, resolved.modeId\n",
	"\treturn resolved.mapId, TML_SEQ[TML_N] or resolved.modeId\n")

local GM = Modules:WaitForChild("GameMode")
patch(GM, "\trunning = false\n\tgeneration += 1\n\thost.Finish()\n",
	"\trunning = false\n"
		.. "\tprint(string.format(\"[TML] end mode=%s scores=%d-%d target=%d timeLimit=%d secondsLeft=%.1f\", "
		.. "current.id, scores[1], scores[2], current.scoreTarget or -1, current.timeLimit or -1, (deadlineMs - nowMs()) / 1000))\n"
		.. "\tgeneration += 1\n\thost.Finish()\n")
patch(GM, "\tdeadlineMs = nowMs() + (current.timeLimit or 480) * 1000\n",
	"\tdeadlineMs = nowMs() + (current.timeLimit or 480) * 1000\n"
		.. "\tTML_NEXT = nowMs() + 30000\n"
		.. "\tprint(string.format(\"[TML] start mode=%s target=%d timeLimit=%d\", current.id, current.scoreTarget or -1, current.timeLimit or -1))\n")
patch(GM, "\t\t\tif nowMs() >= deadlineMs then\n\t\t\t\tGameMode.FinishNow()\n",
	"\t\t\tif TML_NEXT and nowMs() >= TML_NEXT then\n"
		.. "\t\t\t\tTML_NEXT += 30000\n"
		.. "\t\t\t\tprint(string.format(\"[TML] tick mode=%s scores=%d-%d secondsLeft=%.0f\", current.id, scores[1], scores[2], (deadlineMs - nowMs()) / 1000))\n"
		.. "\t\t\tend\n"
		.. "\t\t\tif nowMs() >= deadlineMs then\n\t\t\t\tGameMode.FinishNow()\n")
patch(Modules:WaitForChild("MatchService"),
	"\t\tif realPlayersAlive() == 0 then\n\t\t\tfinishMatch()\n\t\t\treturn true\n\t\tend\n\t\treturn false\n",
	"\t\treturn false\n")
say("patched MatchConfig, VoteService, GameMode, MatchService in the session")

local ends = 0
LogService.MessageOut:Connect(function(message)
	if string.find(message, "[TML] end", 1, true) then
		ends += 1
	end
end)

say("starting run mode")
RunService:Run()

local started = os.time()
local LIMIT = 2000
while ends < 2 and os.time() - started < LIMIT do
	task.wait(5)
end
say("%d team matches ended after %d s", ends, os.time() - started)
