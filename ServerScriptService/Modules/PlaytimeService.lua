-- Compounding playtime awards (#76): every ProgressionData.Playtime.IntervalSeconds spent in the
-- server in one visit pays coins, and each award pays more than the last up to a cap. The ladder
-- lives only in this server's memory, so leaving starts it again and no save is touched.
--
-- All time in the server counts (Oliver, 2026-09-25): alive, dead, spectating, in the lobby, moving
-- or not. It used to pay only stretches where the character moved in half its checks, which since
-- a2ba3b4 left a player who died early and spectated on about 54 coins an hour instead of about 938
-- (reports/playtime-streak-proof.md, finding 2). Roblox's own idle disconnect still ends a visit
-- with no input after about 20 minutes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProgressionData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ProgressionData"))

local RewardService = require(script.Parent:WaitForChild("RewardService"))

local PlaytimeService = {}

local CONFIG = ProgressionData.Playtime
local SAMPLES_PER_AWARD = math.floor(CONFIG.IntervalSeconds / CONFIG.SampleSeconds)

-- [player] = { samples = clock ticks this stretch, awards = paid this visit }
local sessions = {}

local function tick(player, session)
	session.samples += 1
	if session.samples < SAMPLES_PER_AWARD then
		return
	end
	session.samples = 0
	session.awards += 1
	local nextCoins = ProgressionData.PlaytimeCoins(session.awards + 1)
	RewardService.AwardBonusCoins(player, ProgressionData.PlaytimeCoins(session.awards),
		string.format("playtime bonus, next one %d", nextCoins))
end

function PlaytimeService.Start()
	Players.PlayerAdded:Connect(function(player)
		sessions[player] = { samples = 0, awards = 0 }
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		sessions[player] = sessions[player] or { samples = 0, awards = 0 }
	end
	Players.PlayerRemoving:Connect(function(player)
		sessions[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(CONFIG.SampleSeconds)
			for player, session in pairs(sessions) do
				if player.Parent then
					-- One player's error must not stop everyone else's clock.
					local ok, err = pcall(tick, player, session)
					if not ok then
						warn("PlaytimeService:", err)
					end
				end
			end
		end
	end)
end

return PlaytimeService
