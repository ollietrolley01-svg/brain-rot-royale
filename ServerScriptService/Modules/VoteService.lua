-- The lobby vote: three MODE + MAP pairs go up during the countdown, one card per mode (Battle
-- Royale, Team Deathmatch, King of the Hill, in a shuffled order) on three distinct random maps.
-- Most votes wins; a tie among the leaders is broken at random; a vote nobody cast resolves to the
-- Battle Royale card, because that is the main game. Only readied players' votes count: someone
-- staying in the lobby does not pick the match's mode. Bots never reach this module — votes arrive
-- through a remote, and a bot has no client.
--
-- Resolve() answers TWO values, mapId and modeId, and CACHES its answer until the next Open(), so
-- MatchService can ask once for the mode (GameMode.Resolve) and once for the map and get the same
-- match both times — a tie is drawn once, not re-rolled.
--
-- The VoteChanged payload is ADDITIVE over the old map-only shape: each candidate still carries
-- `name`, `description` and `radius` (the map's), so a client drawing the old panel keeps working
-- until it is replaced by VoteScreen.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameModes = require(Shared:WaitForChild("GameModes"))
local MapData = require(Shared:WaitForChild("MapData"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local VoteService = {}

local voteChanged = Remotes.Event("VoteChanged")

-- One card per entry, in this order before the shuffle. A mode listed here must exist in
-- GameModes.Modes; one that does not is skipped with a warning rather than breaking the vote.
VoteService.ModeOrder = { "BattleRoyale", "TeamDeathmatch", "KingOfTheHill" }
-- The card a vote with no votes in it resolves to.
VoteService.DefaultMode = "BattleRoyale"
-- Seedable, so a probe can make the shuffle and the tie-break deterministic.
VoteService.Random = Random.new()

-- Array of { id, modeId, mapId }, and the same by id.
local candidates = {}
local byId = {}
-- [player token] = candidate id. A strong table: entries for live players have been lost from weak
-- ones in this project before. Cleared on PlayerRemoving.
local votes = {}
local open = false
-- What Resolve() decided, kept until the next Open(): { id, mapId, modeId }.
local resolved = nil

-- One place every outbound remote goes: a FireAllClients can throw for a player on their way out,
-- and nothing above it may be undone by that.
local function announce(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		warn("[VoteService] announce failed: " .. tostring(err))
	end
end

-- Readiness is the server's own attribute (MatchService.SetReady), never anything the client sent.
-- pcall'd so a probe's plain-table token without GetAttribute reads as not ready rather than as an
-- error inside a remote handler.
local function isReady(token)
	local ok, ready = pcall(function()
		return token:GetAttribute("Ready") == true
	end)
	return ok and ready == true
end

local function shuffled(list)
	local copy = table.clone(list)
	for index = #copy, 2, -1 do
		local swap = VoteService.Random:NextInteger(1, index)
		copy[index], copy[swap] = copy[swap], copy[index]
	end
	return copy
end

-- Only readied players' votes count, checked HERE and not only when the vote was cast: a player
-- who votes and then un-readies is staying in the lobby, and their vote used to go on counting
-- (and on deciding the match) anyway.
local function tally()
	local counts = {}
	for _, candidate in ipairs(candidates) do
		counts[candidate.id] = 0
	end
	for token, id in pairs(votes) do
		if counts[id] and isReady(token) then
			counts[id] += 1
		end
	end
	return counts
end

local function describe(candidate, count)
	local mode = GameModes.Get(candidate.modeId)
	local map = MapData.Get(candidate.mapId)
	local modeInfo = GameModes.Describe(mode) or { id = candidate.modeId, name = candidate.modeId }
	-- Describe() already carries the colour; said explicitly so the client can rely on it.
	modeInfo.color = mode and mode.color or nil
	return {
		id = candidate.id,
		mode = modeInfo,
		map = {
			id = candidate.mapId,
			name = map.name,
			description = map.description,
			radius = map.radius,
		},
		votes = count,
		-- The old map-only fields, so a client still drawing the old panel keeps working.
		name = map.name,
		description = map.description,
		radius = map.radius,
	}
end

-- Exactly what Broadcast sends, built without sending it. Public for one reason: the gallery that
-- renders the vote screen draws the REAL payload rather than a replica of it, and a replica is how
-- a screen ends up tested against a shape the server does not send.
function VoteService.Snapshot()
	local counts = tally()
	local entries = {}
	for _, candidate in ipairs(candidates) do
		table.insert(entries, describe(candidate, counts[candidate.id]))
	end

	-- String keys: a table keyed by raw UserIds is a sparse array, and RemoteEvents truncate those
	-- at the first gap — the client used to receive an empty table and could never highlight its
	-- own vote.
	local myVotes = {}
	for token, id in pairs(votes) do
		local okId, userId = pcall(function()
			return token.UserId
		end)
		if okId and userId then
			myVotes[tostring(userId)] = id
		end
	end

	return {
		open = open,
		-- The card the match is going to be, once the countdown has run out; nil while the vote is
		-- open and when a countdown is cancelled.
		winner = (not open and resolved) and resolved.id or nil,
		candidates = entries,
		votes = myVotes,
	}
end

function VoteService.Broadcast()
	local snapshot = VoteService.Snapshot()
	announce(function()
		voteChanged:FireAllClients(snapshot)
	end)
end

-- Three cards: every mode once, in a shuffled order, each on a different random map. With fewer
-- maps than modes the maps repeat (they cannot today: 5 maps, 3 modes).
local function rollCandidates()
	local modes = {}
	for _, modeId in ipairs(VoteService.ModeOrder) do
		if GameModes.Get(modeId) then
			table.insert(modes, modeId)
		else
			warn("[VoteService] no such mode in GameModes: " .. tostring(modeId))
		end
	end
	if #modes == 0 then
		modes = { VoteService.DefaultMode }
	end
	modes = shuffled(modes)

	local maps = {}
	while #maps < #modes do
		for _, mapId in ipairs(shuffled(MapData.Order)) do
			if #maps < #modes then
				table.insert(maps, mapId)
			end
		end
	end

	local list = {}
	for index, modeId in ipairs(modes) do
		local mapId = maps[index]
		table.insert(list, { id = modeId .. "|" .. mapId, modeId = modeId, mapId = mapId })
	end
	return list
end

function VoteService.Open()
	candidates = rollCandidates()
	byId = {}
	for _, candidate in ipairs(candidates) do
		byId[candidate.id] = candidate
	end
	votes = {}
	resolved = nil
	open = true
	VoteService.Broadcast()
end

-- Called twice by MatchService: after Resolve() when a match starts (the broadcast then carries the
-- winner), and when a countdown is cancelled (no Resolve, so no winner).
function VoteService.Close()
	open = false
	VoteService.Broadcast()
end

function VoteService.IsOpen()
	return open
end

-- One vote per player; voting again moves it. Validated here, never trusted: the vote has to be
-- open, the id has to be one of the cards up right now, and the voter has to be readied up.
-- State first, the broadcast last.
function VoteService.CastVote(player, candidateId)
	if not open then
		return false, "Voting is closed."
	end
	if type(candidateId) ~= "string" or not byId[candidateId] then
		return false, "That isn't up for vote."
	end
	if not isReady(player) then
		return false, "Ready up to vote."
	end

	votes[player] = candidateId
	VoteService.Broadcast()

	local candidate = byId[candidateId]
	local mode = GameModes.Get(candidate.modeId)
	local map = MapData.Get(candidate.mapId)
	return true, string.format("Voted %s on %s.", mode and mode.name or candidate.modeId, map and map.name or candidate.mapId)
end

-- Which candidate the vote picks: the most voted; a tie among the leaders drawn at random; no votes
-- at all -> the Battle Royale card. Without any candidates (a match started with no countdown, or a
-- probe) it falls back to the battle royale on a random map, so a caller always gets a real answer.
local function decide()
	if #candidates == 0 then
		local mapId = MapData.Order[VoteService.Random:NextInteger(1, #MapData.Order)]
		return { id = VoteService.DefaultMode .. "|" .. mapId, modeId = VoteService.DefaultMode, mapId = mapId }
	end

	local counts = tally()
	local best, leaders = -1, {}
	for _, candidate in ipairs(candidates) do
		local count = counts[candidate.id]
		if count > best then
			best, leaders = count, { candidate }
		elseif count == best then
			table.insert(leaders, candidate)
		end
	end

	if best <= 0 then
		for _, candidate in ipairs(candidates) do
			if candidate.modeId == VoteService.DefaultMode then
				return candidate
			end
		end
	end
	return leaders[VoteService.Random:NextInteger(1, #leaders)]
end

-- Returns mapId, modeId. Cached until the next Open(), so every call between a countdown's end and
-- the next countdown answers the same match.
function VoteService.Resolve()
	if not resolved then
		local pick = decide()
		resolved = { id = pick.id, mapId = pick.mapId, modeId = pick.modeId }
	end
	return resolved.mapId, resolved.modeId
end

-- The candidates as { id, modeId, mapId }, in card order.
function VoteService.GetCandidates()
	return candidates
end

-- A voter who leaves takes their vote with them. Public so a probe can drive it with a fake token.
function VoteService.Forget(token)
	if votes[token] ~= nil then
		votes[token] = nil
		if open then
			VoteService.Broadcast()
		end
	end
end

Players.PlayerRemoving:Connect(VoteService.Forget)

-- Un-readying withdraws the vote too, so the cards' counts go down on every screen at once (tally
-- already ignores it; this is what tells the clients) and re-readying starts from no vote.
local function watchReady(player)
	player:GetAttributeChangedSignal("Ready"):Connect(function()
		if not isReady(player) then
			VoteService.Forget(player)
		end
	end)
end
Players.PlayerAdded:Connect(watchReady)
for _, player in ipairs(Players:GetPlayers()) do
	watchReady(player)
end

return VoteService
