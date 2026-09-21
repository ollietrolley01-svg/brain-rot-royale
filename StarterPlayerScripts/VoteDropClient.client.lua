-- The two screens a player sees before a match: the mode+map vote during the lobby countdown, and
-- the drop-location picker once the map is built.
--
-- This script is the WIRING only — remotes, match state, keys, the cursor and the viewport. The
-- drawing lives in VoteScreen.lua and DropPicker.lua, which are ModuleScripts so tools/gallery.ps1
-- can render exactly what a player sees rather than a replica of it.
--
-- It has its own ScreenGui for two reasons. HudClient's main chunk is three locals from Luau's
-- 200-local limit, which is a silent compile failure; and a ScreenGui of our own can set
-- ZIndexBehavior.Sibling, which is what lets the map's overlays stack inside the disc without
-- fighting the panel's own ZIndex.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local VoteScreen = require(script.Parent:WaitForChild("VoteScreen"))
local DropPicker = require(script.Parent:WaitForChild("DropPicker"))

local matchChanged = Remotes.Event("MatchChanged")
local voteChanged = Remotes.Event("VoteChanged")
local castVote = Remotes.Function("CastVote")
local chooseDrop = Remotes.Event("ChooseDrop")
local getDropMap = Remotes.Function("GetDropMap")

-- How long the winner stays on screen after the countdown ends. The map takes several seconds to
-- build, so this costs nobody anything and answers "what did we get?" without a toast.
local REVEAL_SECONDS = 3

local gui = Instance.new("ScreenGui")
gui.Name = "PreMatchUi"
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
-- Above the HUD (`BrrHud`, default 0), the inventory (8) and the controls hint (20); below the
-- admin HUD (50). Both of these screens are modal moments — nothing else in the game should be
-- drawn over the map you are choosing a landing spot on.
gui.DisplayOrder = 30
gui.Parent = playerGui

local matchState = { state = "Waiting", countdown = 0, dropSelect = false }
local voteState = { open = false, candidates = {}, votes = {} }
local revealUntil = 0
local revealId = nil

local vote = VoteScreen.new({
	parent = gui,
	zIndex = 36,
	onVote = function(candidateId)
		-- Nothing waits on the answer: the tally comes back to everyone through VoteChanged, and a
		-- refusal is already unreachable from here — the cards are disabled and the header says
		-- "Ready up to vote" whenever the server would refuse. pcall'd because an InvokeServer on a
		-- client on its way out throws, and a throw here would take the button's handler with it.
		task.spawn(function()
			pcall(function()
				castVote:InvokeServer(candidateId)
			end)
		end)
	end,
})

local picker = DropPicker.new({
	parent = gui,
	zIndex = 40,
	totalSeconds = MatchConfig.DropSelectSeconds,
	onPick = function(x, z)
		chooseDrop:FireServer(x, z)
	end,
	-- The second half of the cursor fix: CombatClient reads MenuOpen so a click on the map does not
	-- also fire the gun. The picker owns WHEN, this owns the attribute, because a module that a
	-- gallery can render has no player to set attributes on.
	onMenuOpen = function(open)
		player:SetAttribute("MenuOpen", open)
	end,
})

--------------------------------------------------------------------------------
-- The vote
--------------------------------------------------------------------------------

local function isReady()
	return player:GetAttribute("Ready") == true
end

local function renderVote()
	local decided = nil
	if revealId and tick() < revealUntil then
		decided = revealId
	end
	-- The reveal never shares the screen with the picker. It normally ends long before the map is
	-- built, but a map that built in under three seconds would otherwise leave the winner sitting
	-- behind the picker's own dimming overlay.
	if matchState.dropSelect then
		decided = nil
	end
	-- The shop, the inventory and the merge dialog all raise `MenuOpen`, and this screen is drawn
	-- above every one of them (DisplayOrder 30). A vote panel sitting on top of the menu somebody
	-- opened is a worse bug than a vote panel they have to close the menu to see, so it stands aside
	-- and comes straight back — the attribute's own changed signal re-renders below.
	local menuUp = player:GetAttribute("MenuOpen") == true
	local open = voteState.open == true and matchState.state == "Countdown" and not menuUp
	if menuUp then
		decided = nil
	end
	-- The server keys this by UserId as a STRING: a table keyed by raw UserIds is a sparse array and
	-- RemoteEvents truncate those at the first gap, which used to leave the client unable to
	-- highlight its own vote at all.
	local mine = voteState.votes and voteState.votes[tostring(player.UserId)]
	local candidates = {}
	for index, candidate in ipairs(voteState.candidates or {}) do
		candidates[index] = {
			id = candidate.id,
			mode = candidate.mode,
			map = candidate.map,
			votes = candidate.votes,
			mine = mine == candidate.id,
		}
	end
	vote:Render({
		open = open,
		decided = decided,
		candidates = candidates,
		seconds = matchState.countdown or 0,
		total = MatchConfig.LobbyCountdown,
		ready = isReady(),
	})
end

voteChanged.OnClientEvent:Connect(function(state)
	voteState = state or { open = false, candidates = {}, votes = {} }
	-- Close() broadcasts the winner; that broadcast is the reveal's cue.
	if state and state.winner and not state.open then
		revealId = state.winner
		-- tick(), not os.clock(): os.clock() is process CPU time in Roblox, so a clock that
		-- spends its time waiting would never reach the deadline.
		revealUntil = tick() + REVEAL_SECONDS
		task.delay(REVEAL_SECONDS + 0.05, function()
			if revealId == state.winner then
				revealId = nil
				renderVote()
			end
		end)
	elseif state and state.open then
		revealId = nil
	end
	renderVote()
end)

player:GetAttributeChangedSignal("Ready"):Connect(renderVote)
-- Set by the menu, the inventory and the merge dialog — and by this script's own picker, which is
-- why the vote and the picker can never end up on screen together.
player:GetAttributeChangedSignal("MenuOpen"):Connect(renderVote)

-- 1, 2, 3 vote for the first, second and third card. There is no clash with the hotbar: those keys
-- only do anything in CombatClient while a match is in progress, and this screen is only up during
-- the countdown.
UserInputService.InputBegan:Connect(function(input, processed)
	if processed or not voteState.open or matchState.state ~= "Countdown" or not isReady() then
		return
	end
	local index
	if input.KeyCode == Enum.KeyCode.One then
		index = 1
	elseif input.KeyCode == Enum.KeyCode.Two then
		index = 2
	elseif input.KeyCode == Enum.KeyCode.Three then
		index = 3
	end
	if not index then
		return
	end
	local id = vote:CandidateAt(index)
	if id then
		task.spawn(function()
			pcall(function()
				castVote:InvokeServer(id)
			end)
		end)
	end
end)

--------------------------------------------------------------------------------
-- The drop picker
--------------------------------------------------------------------------------

-- One token per window: a map that arrives after its window closed is dropped rather than drawn
-- over the next one.
local dropToken = 0

local function openPicker()
	dropToken += 1
	local token = dropToken
	picker:SetPayload(nil)
	picker:SetSeconds(matchState.countdown or MatchConfig.DropSelectSeconds)
	picker:SetVisible(true)
	task.spawn(function()
		-- Two tries: the first can land in the moment between the window opening and the map being
		-- reachable, and the rate limit allows for exactly this.
		for attempt = 1, 2 do
			local ok, payload = pcall(function()
				return getDropMap:InvokeServer()
			end)
			if token ~= dropToken then
				return
			end
			if ok and type(payload) == "table" then
				picker:SetPayload(payload)
				return
			end
			if attempt == 1 then
				task.wait(1)
			else
				warn("[VoteDropClient] no drop map from the server; the picker stays on its placeholder")
			end
			if token ~= dropToken then
				return
			end
		end
	end)
end

local function updateDrop()
	local active = matchState.dropSelect == true and isReady()
	if active and not picker.visible then
		openPicker()
	elseif not active and picker.visible then
		dropToken += 1
		picker:SetVisible(false)
	end
	if active then
		picker:SetSeconds(matchState.countdown or 0)
	end
end

matchChanged.OnClientEvent:Connect(function(state)
	matchState = state or matchState
	updateDrop()
	renderVote()
end)

--------------------------------------------------------------------------------
-- The viewport
--------------------------------------------------------------------------------

-- A screen that lays out once and never again is how the short and tall versions end up shipped
-- without ever having run: the menu shell's `SetViewport` turned out never to be called in the
-- game at all. Both screens re-lay themselves whenever the viewport changes, which also covers a
-- phone being turned over mid-countdown.
local camera = workspace.CurrentCamera
if camera then
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		vote:Relayout()
		if picker.visible then
			picker:Layout()
		end
	end)
end
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	local newCamera = workspace.CurrentCamera
	if newCamera then
		newCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			vote:Relayout()
			if picker.visible then
				picker:Layout()
			end
		end)
	end
end)

renderVote()
