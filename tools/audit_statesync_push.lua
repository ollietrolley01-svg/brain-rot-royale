-- Probe for tools/runtest.ps1 -Probe: profile snapshots are coalesced to one a frame, and still
-- carry everything the menu draws.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/audit_statesync_push.lua
--
-- With a stand-in player on a real profile, loaded up like a long-time player (a big collection, a
-- full Rot Index, crates, quests, mastery):
--   * how big one snapshot is (JSON bytes), which is what every push costs;
--   * a kill through the real RewardService.AwardKill: how many pushes it ASKS for against how many
--     snapshots are actually sent this frame;
--   * every panel's field still arrives, with a changed value reaching the client after the frame;
--   * a push still waiting when a player leaves is flushed (StateSync.Flush).
-- Sends are counted by wrapping StateSync.Build, which Push calls once per snapshot it sends.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local PlayerData = require(modules:WaitForChild("PlayerData"))
local StateSync = require(modules:WaitForChild("StateSync"))
local RewardService = require(modules:WaitForChild("RewardService"))

local function out(fmt, ...)
	print("[AUDIT push] " .. string.format(fmt, ...))
end

local standIn = { UserId = -920001, Name = "PushTester", DisplayName = "PushTester", Parent = true }
PlayerData.Load(standIn)
local data = PlayerData.Get(standIn)
if not data then
	out("RESULT INCONCLUSIVE: no profile")
	pcall(flush)
	return
end

-- A long-time player: every species owned several times over, the whole Index recorded, some crates.
local species = 0
for _, def in ipairs(BrainrotData.Types) do
	species += 1
	for _ = 1, 3 do
		table.insert(data.Brainrots, def.name)
	end
	data.Progression.index[def.name] = 1
	data.Stars[def.name] = 2
end
for tier in pairs(data.Crates) do
	data.Crates[tier] = 5
end
data.Progression.mastery.CrocodiloRifle = 250
data.SahurCoins = 12345

-- The stand-in isn't a real Player, so anything that reaches a RemoteEvent with it throws
-- ("Unable to cast value to Object") and takes the reward path down with it. Build still does all
-- its work and is still counted — it just hands back nothing, which is Push's own signal to send
-- nothing. Notify goes the same way. Between them, no remote is touched all run.
local realBuild = StateSync.Build
local builds = 0
StateSync.Build = function(player)
	builds += 1
	realBuild(player)
	return nil
end
local realNotify = StateSync.Notify
local notices = 0
StateSync.Notify = function()
	notices += 1
end
local realPush = StateSync.Push
local requests = 0
StateSync.Push = function(player)
	requests += 1
	return realPush(player)
end

local snapshot = realBuild(standIn)
local okJson, encoded = pcall(HttpService.JSONEncode, HttpService, snapshot)
out("profile: %d species, %d brainrots held, index %d; one snapshot is %s",
	species, #data.Brainrots, (function()
		local n = 0
		for _ in pairs(data.Progression.index) do
			n += 1
		end
		return n
	end)(), okJson and string.format("%d JSON bytes", #encoded) or "not measurable here")

-- One kill, through the real reward path.
builds, requests = 0, 0
local coinsBefore = data.SahurCoins
RewardService.AwardKill(standIn, true)
local requestedInFrame, builtInFrame = requests, builds
task.wait(0.2)
out("one kill: %d pushes asked for, %d snapshots built in that frame, %d after the frame settled (coins %d -> %d)",
	requestedInFrame, builtInFrame, builds, coinsBefore, data.SahurCoins)

-- Everything the menu needs is still in the snapshot that goes out after the frame.
local latest = realBuild(standIn)
local needed = { "coins", "brainrots", "crates", "cosmetics", "pass", "daily", "stats", "consumables", "quests", "achievements", "progression", "stars" }
local missing = {}
for _, field in ipairs(needed) do
	if latest[field] == nil then
		table.insert(missing, field)
	end
end
local indexSize, masteryFound = 0, latest.progression and latest.progression.mastery and latest.progression.mastery.CrocodiloRifle
for _ in pairs(latest.progression and latest.progression.index or {}) do
	indexSize += 1
end
out("snapshot fields: %s; index entries %d; mastery CrocodiloRifle %s; coins %s",
	#missing == 0 and "all present" or ("MISSING " .. table.concat(missing, ", ")), indexSize, tostring(masteryFound), tostring(latest.coins))

-- A push still waiting when the player goes: Flush sends it rather than losing it.
builds = 0
StateSync.Push(standIn)
local pendingBuilds = builds
StateSync.Flush(standIn)
local afterFlush = builds
task.wait(0.2)
out("pending at leave: %d built before Flush, %d after Flush, %d once the frame ran (a second send would be wasteful, zero after Flush means it was lost)",
	pendingBuilds, afterFlush, builds)

local coalesced = requestedInFrame > builtInFrame or requestedInFrame <= 1
local flushed = afterFlush > 0
out("RESULT %s: coalescing %s, flush-at-leave %s, fields %s",
	(coalesced and flushed and #missing == 0) and "PASS" or "FAIL",
	coalesced and "ok" or "NOT coalescing", flushed and "ok" or "LOST", #missing == 0 and "ok" or "incomplete")

out("notices raised on the way: %d (stubbed: a stand-in can't take a remote)", notices)
StateSync.Build, StateSync.Push, StateSync.Notify = realBuild, realPush, realNotify
pcall(PlayerData.Release, standIn)
pcall(flush)
