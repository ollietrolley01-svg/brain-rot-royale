-- Two-party brainrot trading, run entirely from the lobby menu.
--
-- Anti-scam rule that matters: changing your offer clears BOTH confirmations. Without that,
-- someone can wait for you to confirm and then swap a Legendary for a Common.
--
-- Ownership is re-verified at execution time, not at offer time, so nothing can be traded
-- away twice or sold out from under a pending trade.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local StateSync = require(script.Parent:WaitForChild("StateSync"))

local TradeService = {}

local MAX_OFFER = 9
local INVITE_TIMEOUT = 30

local tradeInvite = Remotes.Event("TradeInvite")
local tradeChanged = Remotes.Event("TradeChanged")

local sessionOf = {}
local inviteFor = {}

-- Set by Bootstrap to MatchService.IsAlive: you can't trade while you're in a match.
TradeService.IsBusy = function()
	return false
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function partnerOf(session, player)
	return session.a == player and session.b or session.a
end

local function counts(list)
	local tally = {}
	for _, name in ipairs(list) do
		tally[name] = (tally[name] or 0) + 1
	end
	return tally
end

-- True only if `data.Brainrots` contains at least as many of each offered name.
local function canFulfil(data, offer)
	local owned = counts(data.Brainrots)
	for name, needed in pairs(counts(offer)) do
		if (owned[name] or 0) < needed then
			return false
		end
	end
	return true
end

-- Stars stay with the profile, not the copy (BrainrotData: they can't be moved to another
-- account). Trading your last copy away therefore left the stars behind, and every later copy of
-- that species (from a crate, Robux or a trade) arrived at full stars for free, over and over.
-- Spares are tradable; the last copy of a merged one isn't, as with selling. Returns the first
-- merged name `offer` would take the last copy of, and its stars.
local function strandsStars(data, offer)
	local owned = counts(data.Brainrots)
	for name, offered in pairs(counts(offer)) do
		local stars = data.Stars and data.Stars[name] or 0
		if stars > 0 and (owned[name] or 0) - offered < 1 then
			return name, stars
		end
	end
	return nil
end

local function describe(list)
	local entries = {}
	for _, name in ipairs(list) do
		local def = BrainrotData.Get(name)
		table.insert(entries, {
			name = name,
			rarity = def and def.rarity or "Common",
			coinValue = def and def.coinValue or 0,
		})
	end
	return entries
end

local function pushSession(session)
	for _, player in ipairs({ session.a, session.b }) do
		if player.Parent then
			local other = partnerOf(session, player)
			tradeChanged:FireClient(player, {
				active = true,
				partner = other.DisplayName,
				partnerUserId = other.UserId,
				yours = describe(session.offers[player]),
				theirs = describe(session.offers[other]),
				youConfirmed = session.confirmed[player],
				theyConfirmed = session.confirmed[other],
				maxOffer = MAX_OFFER,
			})
		end
	end
end

local function closeSession(session, message)
	sessionOf[session.a] = nil
	sessionOf[session.b] = nil

	for _, player in ipairs({ session.a, session.b }) do
		if player.Parent then
			tradeChanged:FireClient(player, { active = false })
			if message then
				StateSync.Notify(player, message)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Invites
--------------------------------------------------------------------------------

function TradeService.Request(from, target)
	if from == target then
		return false, "You can't trade with yourself."
	end
	if not target or not target.Parent then
		return false, "That player has left."
	end
	if sessionOf[from] or sessionOf[target] then
		return false, "One of you is already in a trade."
	end
	if TradeService.IsBusy(from) or TradeService.IsBusy(target) then
		return false, "Trading is lobby-only."
	end

	inviteFor[target] = { from = from, at = os.time() }
	tradeInvite:FireClient(target, { fromName = from.DisplayName, fromUserId = from.UserId })

	return true, "Trade request sent to " .. target.DisplayName .. "."
end

function TradeService.Respond(target, accept)
	local invite = inviteFor[target]
	inviteFor[target] = nil

	if not invite then
		return false, "That request expired."
	end
	-- os.time, not os.clock: os.clock is CPU time in Roblox, so the 30 s expiry ran slow.
	if os.time() - invite.at > INVITE_TIMEOUT then
		return false, "That request expired."
	end

	local from = invite.from
	if not from.Parent then
		return false, "That player has left."
	end

	if not accept then
		StateSync.Notify(from, target.DisplayName .. " declined the trade.", true)
		return true, "Declined."
	end

	if sessionOf[from] or sessionOf[target] then
		return false, "One of you is already in a trade."
	end
	if TradeService.IsBusy(from) or TradeService.IsBusy(target) then
		return false, "Trading is lobby-only."
	end

	local session = {
		a = from,
		b = target,
		offers = { [from] = {}, [target] = {} },
		confirmed = { [from] = false, [target] = false },
	}

	sessionOf[from] = session
	sessionOf[target] = session
	pushSession(session)

	return true, "Trading with " .. from.DisplayName .. "."
end

--------------------------------------------------------------------------------
-- Offers
--------------------------------------------------------------------------------

function TradeService.Offer(player, name, add)
	local session = sessionOf[player]
	if not session then
		return false, "You aren't in a trade."
	end
	if session.executing then
		return false, "That trade is already going through."
	end
	if not BrainrotData.Get(name) then
		return false, "No such brainrot."
	end

	local offer = session.offers[player]

	if add then
		if #offer >= MAX_OFFER then
			return false, string.format("You can offer at most %d at a time.", MAX_OFFER)
		end

		local data = PlayerData.Get(player)
		if not data then
			return false, "Profile still loading."
		end

		local candidate = table.clone(offer)
		table.insert(candidate, name)
		if not canFulfil(data, candidate) then
			return false, "You don't have another one of those."
		end

		local merged, stars = strandsStars(data, candidate)
		if merged then
			return false, string.format("%s is merged (%s) — you can't trade away your last copy.", merged, BrainrotData.StarText(stars))
		end

		table.insert(offer, name)
	else
		local index = table.find(offer, name)
		if not index then
			return false, "That isn't in your offer."
		end
		table.remove(offer, index)
	end

	-- Any change to the table invalidates both confirmations.
	session.confirmed[session.a] = false
	session.confirmed[session.b] = false

	pushSession(session)
	return true, nil
end

-- Runs once per session. It yields in the saves below, and while it did the session stayed open
-- with both confirmations still set, so a second TradeConfirm in that moment ran the whole trade
-- again: anyone with spare copies could take a second of what the other side offered. The session
-- is marked executing first (Confirm, Offer and Cancel refuse it) and closed before anything yields.
local function execute(session)
	if session.executing then
		return
	end
	session.executing = true
	local dataA = PlayerData.Get(session.a)
	local dataB = PlayerData.Get(session.b)

	if not dataA or not dataB then
		closeSession(session, "Trade cancelled — profile not loaded.")
		return
	end

	local offerA = session.offers[session.a]
	local offerB = session.offers[session.b]

	if not canFulfil(dataA, offerA) or not canFulfil(dataB, offerB) then
		closeSession(session, "Trade cancelled — someone no longer owns what they offered.")
		return
	end

	-- Offer checked the last-copy rule against the collection as it was then. Copies can leave
	-- between the offer and the confirm, so it is checked again against what is actually here.
	for _, side in ipairs({ { session.a, dataA, offerA }, { session.b, dataB, offerB } }) do
		local merged, stars = strandsStars(side[2], side[3])
		if merged then
			closeSession(session, string.format("Trade cancelled — %s's %s is merged (%s) and that was their last copy.",
				side[1].DisplayName, merged, BrainrotData.StarText(stars)))
			return
		end
	end

	-- A profile that can't be written must not trade. The brainrots would move in memory and then die
	-- with the session, so one side loses what they gave and the other never really got it. That's a
	-- temporary profile from a failed load, or a session whose lock another server has taken
	-- (PlayerData). Skipped where there's no DataStore at all (Studio), so playtests can still trade.
	if PlayerData.HasStore() and (not PlayerData.CanSave(session.a) or not PlayerData.CanSave(session.b)) then
		closeSession(session, "Trade cancelled — someone's progress isn't saving right now. Rejoin and try again.")
		return
	end

	local function move(fromData, toData, offer)
		for _, name in ipairs(offer) do
			local index = table.find(fromData.Brainrots, name)
			if index then
				table.remove(fromData.Brainrots, index)
				table.insert(toData.Brainrots, name)
			end
		end
	end

	move(dataA, dataB, offerA)
	move(dataB, dataA, offerB)

	-- Set by Bootstrap to ProgressionService.OnTradeMoved: a species one side only has as bought with
	-- Robux goes over as bought, so a trade can't turn it into claimable Brain Cells. Runs before the
	-- saves below yield, so nothing can scan the collections first. Protected: a hook error must never
	-- stop a trade that has already moved real items from saving.
	if TradeService.OnTradeMoved then
		local ok, err = pcall(TradeService.OnTradeMoved, session.a, session.b, offerA, offerB)
		if not ok then
			warn("[TradeService] OnTradeMoved failed: " .. tostring(err))
		end
	end

	-- A showcased brainrot that just left the inventory would render a podium for something
	-- the player no longer owns.
	if dataA.Showcase and not table.find(dataA.Brainrots, dataA.Showcase) then
		dataA.Showcase = nil
	end
	if dataB.Showcase and not table.find(dataB.Brainrots, dataB.Showcase) then
		dataB.Showcase = nil
	end

	-- Closed before the saves yield, so nothing can reach this session again.
	closeSession(session, "Trade complete.")

	PlayerData.Save(session.a)
	PlayerData.Save(session.b)

	StateSync.Push(session.a)
	StateSync.Push(session.b)

	if TradeService.OnTradeComplete then
		TradeService.OnTradeComplete()
	end
end

function TradeService.Confirm(player, value)
	local session = sessionOf[player]
	if not session then
		return false, "You aren't in a trade."
	end
	if session.executing then
		return false, "That trade is already going through."
	end

	session.confirmed[player] = value == true
	pushSession(session)

	if session.confirmed[session.a] and session.confirmed[session.b] then
		execute(session)
	end

	return true, nil
end

function TradeService.Cancel(player)
	local session = sessionOf[player]
	if not session then
		return false, "You aren't in a trade."
	end
	if session.executing then
		return false, "That trade is already going through."
	end
	closeSession(session, player.DisplayName .. " cancelled the trade.")
	return true, nil
end

function TradeService.CancelAll(reason)
	local seen = {}
	for _, session in pairs(sessionOf) do
		if not seen[session] then
			seen[session] = true
			closeSession(session, reason)
		end
	end
	table.clear(inviteFor)
end

function TradeService.InSession(player)
	return sessionOf[player] ~= nil
end

Players.PlayerRemoving:Connect(function(player)
	inviteFor[player] = nil
	local session = sessionOf[player]
	if session then
		closeSession(session, player.DisplayName .. " left — trade cancelled.")
	end
end)

return TradeService
