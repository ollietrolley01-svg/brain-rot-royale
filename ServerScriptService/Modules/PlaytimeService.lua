-- Compounding playtime awards (#76): every ProgressionData.Playtime.IntervalSeconds of active
-- play in one visit pays coins, and each award pays more than the last up to a cap. The ladder
-- lives only in this server's memory, so leaving starts it again and no save is touched.
--
-- "Active" is judged from the server, which can't see input: every SampleSeconds the player's
-- root part is checked, and a check counts if it moved MoveStuds since the last one. No living
-- character to check (dead, spectating, between respawns) does NOT count: it used to, so an idle
-- player who died at the drop and sat on the spectator camera was paid the whole ladder -- a
-- battle royale AFK farm. Standing still in the lobby all stretch pays nothing either.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProgressionData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ProgressionData"))

local RewardService = require(script.Parent:WaitForChild("RewardService"))

local PlaytimeService = {}

local CONFIG = ProgressionData.Playtime
local SAMPLES_PER_AWARD = math.floor(CONFIG.IntervalSeconds / CONFIG.SampleSeconds)

-- [player] = { samples = checks this stretch, active = active checks, awards = paid this visit, last = Vector3? }
local sessions = {}

local function livingRoot(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart")
end

-- One check. Returns true when it counts as active.
local function sample(session, player)
	local root = livingRoot(player)
	if not root then
		session.last = nil
		return false
	end
	local position = root.Position
	local last = session.last
	session.last = position
	return last ~= nil and (position - last).Magnitude >= CONFIG.MoveStuds
end

local function tick(player, session)
	session.samples += 1
	if sample(session, player) then
		session.active += 1
	end
	if session.samples < SAMPLES_PER_AWARD then
		return
	end
	local earned = session.active >= CONFIG.MinActiveSamples
	session.samples, session.active = 0, 0
	if earned then
		session.awards += 1
		local nextCoins = ProgressionData.PlaytimeCoins(session.awards + 1)
		RewardService.AwardBonusCoins(player, ProgressionData.PlaytimeCoins(session.awards),
			string.format("playtime bonus, next one %d", nextCoins))
	end
end

function PlaytimeService.Start()
	Players.PlayerAdded:Connect(function(player)
		sessions[player] = { samples = 0, active = 0, awards = 0 }
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		sessions[player] = sessions[player] or { samples = 0, active = 0, awards = 0 }
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
