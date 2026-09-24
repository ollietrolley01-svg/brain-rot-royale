-- The all-time leaderboard: total wins per player across every server, in an OrderedDataStore.
--
-- Wins are written when they happen (RewardService), and the top of the board is read every so
-- often for the lobby. Both are pcall'd: in Studio, or before the place is published, the store
-- isn't available and the board says so instead of erroring.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local GlobalBoardService = {}

local STORE_NAME = "BRR_GlobalWins_v1"
local CACHE_SECONDS = 60

local store = nil
local cached = nil
local cachedAt = -math.huge
local names = {}

local function getStore()
	if store then
		return store
	end
	local ok, result = pcall(function()
		return DataStoreService:GetOrderedDataStore(STORE_NAME)
	end)
	if ok then
		store = result
	end
	return store
end

local function nameFor(userId)
	if names[userId] then
		return names[userId]
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	-- Only a real name is kept: a throttled lookup is tried again next refresh rather than showing
	-- "Player 123" for the rest of the server's life.
	if ok and name then
		names[userId] = name
		return name
	end
	return "Player " .. tostring(userId)
end

-- Records a player's win total. Fire-and-forget; a failure just means the board lags.
function GlobalBoardService.SubmitWins(player, wins)
	task.spawn(function()
		local ordered = getStore()
		if not ordered then
			return
		end
		pcall(function()
			ordered:SetAsync(tostring(player.UserId), math.floor(wins))
		end)
	end)
end

-- The top `count` as { { name, wins } }, or nil when the store can't be reached. Cached, since
-- the lobby asks every minute and DataStore reads are budgeted.
function GlobalBoardService.Top(count)
	if cached and os.clock() - cachedAt < CACHE_SECONDS then
		return cached
	end
	local ordered = getStore()
	if not ordered then
		return nil
	end
	local ok, page = pcall(function()
		return ordered:GetSortedAsync(false, count):GetCurrentPage()
	end)
	if not ok then
		-- A hiccup on a live server keeps the last good board (nil means "no store" to the lobby,
		-- which blanks it to the Studio message). cachedAt is left alone, so the next ask retries.
		return cached
	end
	local list = {}
	for _, entry in ipairs(page) do
		local userId = tonumber(entry.key)
		if userId then
			table.insert(list, { name = nameFor(userId), wins = entry.value })
		end
	end
	cached, cachedAt = list, os.clock()
	return list
end

return GlobalBoardService
