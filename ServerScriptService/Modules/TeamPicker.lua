-- The team picker: a team mode's short window, after the vote has picked the mode and the map is
-- built, in which each player in the match chooses a side (or leaves it to AUTO).
--
-- It is the team modes' answer to the battle royale's drop window, and it sits in the same place in
-- MatchService.startMatch: the one moment when the mode is decided and nobody has a body yet. The
-- battle royale never opens it (TeamPickerRules.ShowsFor).
--
-- SERVER-AUTHORITATIVE. A client only ever says "I'd like side N"; this module decides:
--   * balance -- a side holds at most ceil(humans / 2) humans (TeamPickerRules), so the final split is
--     never more than one human apart, and the bots fill both sides afterwards (ModeTeams deals them
--     onto the smaller side, counting the picked seats that have no body yet);
--   * timing  -- a pick that arrives once the window has closed, or after its deadline, is refused as
--     stale, however the remote was delayed (Bootstrap also rate-limits it: RateLimit "PickTeam");
--   * leavers -- a player who leaves frees their seat, and if the cap drops under a side's picks the
--     newest picks there go back to AUTO;
--   * AUTO    -- whoever did not pick is dealt onto the side with fewer humans when the window closes.
-- Late joiners after the window: auto-assigned by ModeTeams.Assign, no picker (it is a respawn mode,
-- they are needed on the smaller side, and a picker mid-match would cover a live screen).
--
-- The hand-off to ModeTeams is one call, ModeTeams.SetPicks(sides), before anyone is placed.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameModes = require(Shared:WaitForChild("GameModes"))
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Rules = require(Shared:WaitForChild("TeamPickerRules"))

local TeamPicker = {}

-- How long the window is open. A few seconds more than it takes to read two cards and tap one.
TeamPicker.Seconds = MatchConfig.TeamPickSeconds or 12
-- Once every human has picked, the window closes this soon, so a party can still swap sides.
TeamPicker.AllPickedGrace = 2
-- The vote's winner reveal is a 3-second panel in the middle of the screen (VoteDropClient's
-- REVEAL_SECONDS), started when the vote closes. The picker never opens on top of it.
TeamPicker.RevealGuard = 3.5
-- How many names a card lists before "+N more".
TeamPicker.RosterMax = 8

-- Test seams: the clock, the wait, and where snapshots go. Wall clock in seconds (see ModeTeams on
-- why never os.clock for a deadline).
TeamPicker.Clock = function()
	return DateTime.now().UnixTimestampMillis / 1000
end
TeamPicker.Wait = function(seconds)
	task.wait(seconds)
end
local changed = Remotes.Event("TeamPickerChanged")
TeamPicker.Send = function(player, snapshot)
	changed:FireClient(player, snapshot)
end
-- Lazily, so requiring this module never requires ModeTeams (and its map modules) first.
TeamPicker.ModeTeams = nil

local open = false
local deadline = 0
local modeId = nil
local total = 0
local order = {}     -- the humans, in match order
local members = {}   -- token -> true
local picks = {}     -- token -> 1 | 2 (AUTO is "absent")
local pickedAt = {}  -- token -> sequence number of the pick, for Overflow
local sequence = 0
local firstTie = 1

local function announce(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		warn("[TeamPicker] announce failed: " .. tostring(err))
	end
end

local function nameOf(token)
	if typeof(token) == "Instance" then
		return token.DisplayName ~= "" and token.DisplayName or token.Name
	end
	return type(token) == "table" and (token.DisplayName or token.Name) or tostring(token)
end

function TeamPicker.IsOpen()
	return open
end

function TeamPicker.SecondsLeft()
	if not open then
		return 0
	end
	return math.max(0, deadline - TeamPicker.Clock())
end

function TeamPicker.HumanCount()
	return #order
end

function TeamPicker.PickOf(token)
	return picks[token] or Rules.Auto
end

-- What one player sees. Everyone gets the same rosters; `mine`, `full` and `refused` are theirs.
function TeamPicker.Snapshot(forToken, refused)
	local projected, humans = Rules.Resolve(order, picks, firstTie)
	local size1, size2, bots1, bots2 = Rules.Sizes(total, humans[1], humans[2])
	local cap = Rules.HumanCap(#order)
	local teams = {}
	for team = 1, 2 do
		local names = {}
		for _, token in ipairs(order) do
			if picks[token] == team then
				table.insert(names, { name = nameOf(token), me = token == forToken })
			end
		end
		local shown = {}
		for i = 1, math.min(#names, TeamPicker.RosterMax) do
			shown[i] = names[i]
		end
		local info = GameModes.Team(team) or {}
		teams[team] = {
			id = info.id,
			name = info.name,
			picked = #names,
			roster = shown,
			more = math.max(0, #names - TeamPicker.RosterMax),
			bots = team == 1 and bots1 or bots2,
			size = team == 1 and size1 or size2,
			projected = humans[team],
			full = not Rules.CanPick(picks, #order, forToken, team),
		}
	end
	local undecided = 0
	for _, token in ipairs(order) do
		if not picks[token] then
			undecided += 1
		end
	end
	return {
		open = open,
		mode = modeId,
		secondsLeft = TeamPicker.SecondsLeft(),
		seconds = TeamPicker.Seconds,
		cap = cap,
		humans = #order,
		total = total,
		undecided = undecided,
		teams = teams,
		mine = picks[forToken] or Rules.Auto,
		autoSide = projected[forToken],
		refused = refused,
	}
end

function TeamPicker.Broadcast()
	for _, token in ipairs(order) do
		if typeof(token) ~= "Instance" or token.Parent then
			announce(TeamPicker.Send, token, TeamPicker.Snapshot(token))
		end
	end
end

-- Opens the window for `humans` (the players joining, in order) in a match of `matchTotal` bodies.
-- Refuses (returns false) for a mode that has no sides: the battle royale never shows the picker.
function TeamPicker.Open(humans, matchTotal, mode)
	if not Rules.ShowsFor(mode) then
		return false
	end
	open = true
	modeId = mode.id
	total = matchTotal or #humans
	table.clear(order)
	table.clear(members)
	table.clear(picks)
	table.clear(pickedAt)
	sequence = 0
	for _, token in ipairs(humans) do
		if not members[token] then
			members[token] = true
			table.insert(order, token)
		end
	end
	firstTie = math.random(1, 2)
	deadline = TeamPicker.Clock() + TeamPicker.Seconds
	TeamPicker.Broadcast()
	return true
end

-- A player's request. `team` is 1, 2, or 0 for AUTO. Returns ok, reason.
function TeamPicker.Pick(token, team)
	if not open then
		return false, "closed"
	end
	if TeamPicker.Clock() >= deadline then
		return false, "stale"
	end
	if not members[token] then
		return false, "not in match"
	end
	if type(team) ~= "number" or team ~= team then
		return false, "bad team"
	end
	local ok, reason = Rules.CanPick(picks, #order, token, team)
	if not ok then
		announce(TeamPicker.Send, token, TeamPicker.Snapshot(token, reason))
		return false, reason
	end
	if team == Rules.Auto then
		picks[token], pickedAt[token] = nil, nil
	elseif picks[token] ~= team then
		sequence += 1
		picks[token], pickedAt[token] = team, sequence
	end
	-- Everyone has chosen: nobody left to wait for, bar a moment for a party to swap.
	local waiting = false
	for _, member in ipairs(order) do
		if not picks[member] then
			waiting = true
			break
		end
	end
	if not waiting then
		deadline = math.min(deadline, TeamPicker.Clock() + TeamPicker.AllPickedGrace)
	end
	TeamPicker.Broadcast()
	return true
end

-- A player left: their seat is free, and any side now over the cap loses its newest picks to AUTO.
function TeamPicker.Forget(token)
	if not members[token] then
		return
	end
	members[token], picks[token], pickedAt[token] = nil, nil, nil
	for index, member in ipairs(order) do
		if member == token then
			table.remove(order, index)
			break
		end
	end
	for _, bumped in ipairs(Rules.Overflow(picks, #order, pickedAt)) do
		picks[bumped], pickedAt[bumped] = nil, nil
	end
	if open then
		TeamPicker.Broadcast()
	end
end

-- Closes the window and hands every human's side to ModeTeams. Returns token -> team.
function TeamPicker.Close()
	local sides = Rules.Resolve(order, picks, firstTie)
	open = false
	local ModeTeams = TeamPicker.ModeTeams or require(script.Parent:WaitForChild("ModeTeams"))
	ModeTeams.SetPicks(sides)
	TeamPicker.Broadcast()
	return sides
end

-- The whole window, blocking, for MatchService.startMatch. `notBefore` is the clock time before which
-- it must not open (the vote's reveal); `onTick(secondsLeft)` is called as the countdown moves.
-- Returns token -> team, or nil when the mode has no picker.
function TeamPicker.Run(humans, matchTotal, mode, notBefore, onTick)
	if not Rules.ShowsFor(mode) then
		return nil
	end
	local hold = (notBefore or 0) - TeamPicker.Clock()
	if hold > 0 then
		TeamPicker.Wait(hold)
	end
	TeamPicker.Open(humans, matchTotal, mode)
	local shown = nil
	while open and TeamPicker.Clock() < deadline do
		local left = math.ceil(TeamPicker.SecondsLeft())
		if left ~= shown then
			shown = left
			if onTick then
				announce(onTick, left)
			end
		end
		TeamPicker.Wait(0.25)
	end
	return TeamPicker.Close()
end

Players.PlayerRemoving:Connect(function(player)
	TeamPicker.Forget(player)
end)

return TeamPicker
