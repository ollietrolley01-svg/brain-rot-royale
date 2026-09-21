-- Rot Rank and Prestige, Brain Cells, weapon mastery, the Rot Index and the Cell Shop: the long
-- grind that keeps going after the Brainrot Pass is finished. The numbers live in
-- Shared/ProgressionData; this module applies them to profiles.
--
-- Wired from Bootstrap, never required by the modules it listens to:
--   BattlePassService.OnXp       -> OnPassXp       every point of pass XP also feeds Rot Rank
--   MatchService.OnKillCredited  -> OnKillCredited credited eliminations feed gun mastery
--   join, crate opens, trades, the Daily Spin -> RecordIndex
--   remotes Prestige / ClaimIndex / BuyCellOffer
--
-- Every entry point first makes sure the profile has been migrated (Migrate): a profile from
-- before progression existed gets its rank from the pass XP it already earned, and its Index from
-- the brainrots it owns or has stars or companion XP on. Backfilled ranks pay Cells, never crates.
--
-- Brain Cells never pass through RewardService.AddCoins or any gamepass check, so no pass can
-- multiply them. Rank crates go into the crate inventory through CrateService.Give and are opened
-- with the same odds code as every other crate.
--
-- Handlers that spend or claim validate everything first and then write, with no yields in
-- between, so a double-click or two menus can't pay twice.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local ProgressionData = require(Shared:WaitForChild("ProgressionData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))

local AchievementService = require(script.Parent:WaitForChild("AchievementService"))
local Combatants = require(script.Parent:WaitForChild("Combatants"))
local CrateService = require(script.Parent:WaitForChild("CrateService"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local RewardService = require(script.Parent:WaitForChild("RewardService"))
local StateSync = require(script.Parent:WaitForChild("StateSync"))

local ProgressionService = {}

-- Prestiging to at least this is announced to the whole server.
local SHOUT_PRESTIGE = 1

-- Minimum seconds between two calls of the same remote from one player.
ProgressionService.RemoteCooldown = 0.35
-- How long after joining the one-time "your Rot Rank is set from your pass XP" toast waits, so the
-- client's HUD is listening when it arrives.
ProgressionService.WelcomeToastDelay = 12

local lastCall = {}
local pushPending = {}
-- For the results card: where each player stood when the match began, and the mastery tiers they
-- reached during it.
local matchStart = {}
local matchTiers = {}

local PUSH_DELAY = 1

-- Pushing state to a client is transport, like a toast: it fires a remote, and a remote can fail. A
-- failed push must not throw out of the claim or the purchase that earned the state being pushed --
-- the client would be told its claim failed after the profile had already been written. It warns
-- instead, and the next push (or the next join) carries the state.
local function pushNow(player)
	local ok, err = pcall(StateSync.Push, player)
	if not ok then
		warn("[Progression] couldn't push state to " .. tostring(player) .. ": " .. tostring(err))
	end
end

local function schedulePush(player)
	if pushPending[player] then
		return
	end
	pushPending[player] = true
	task.delay(PUSH_DELAY, function()
		pushPending[player] = nil
		if player.Parent then
			pushNow(player)
		end
	end)
end

-- True if `player` called `key` too recently; otherwise records the call.
function ProgressionService.RateLimited(player, key)
	local now = os.clock()
	local calls = lastCall[player]
	if not calls then
		calls = {}
		lastCall[player] = calls
	end
	if calls[key] and now - calls[key] < ProgressionService.RemoteCooldown then
		return true
	end
	calls[key] = now
	return false
end

local function plural(count, word, many)
	return count == 1 and word or (many or word .. "s")
end

-- A toast is news about something that already happened, so a failed one must never undo it or stop
-- the code after it. It still warns: a message nobody can send is worth knowing about.
local function announce(player, message, isError)
	local ok, err = pcall(StateSync.Notify, player, message, isError)
	if not ok then
		warn("[Progression] couldn't tell " .. tostring(player) .. ": " .. tostring(err))
	end
end

local function grantCells(progression, amount)
	amount = math.floor(amount)
	if amount <= 0 then
		return 0
	end
	progression.cells += amount
	progression.cellsEarned += amount
	return amount
end

local function syncAttributes(player, progression)
	player:SetAttribute("RotRank", ProgressionData.RankForXp(progression.xp))
	player:SetAttribute("Prestige", progression.prestige)
end

-- Hands over every prestige and mastery cosmetic whose condition is met and that isn't owned yet.
-- Run on join too, so progress made before a cosmetic existed still unlocks it. Returns how many.
local function syncCosmetics(player, data, progression, quiet)
	local granted = 0
	for _, entry in ipairs(ProgressionData.RankCosmetics) do
		local item = CosmeticData.Get(entry.id)
		if item and item.rankOnly and not data.Cosmetics.owned[entry.id] and ProgressionData.CosmeticEarned(entry, progression) then
			data.Cosmetics.owned[entry.id] = true
			granted += 1
			if not quiet then
				-- "Silver Rot Aura", not "Silver Rot Aura aura".
				local kindWord = item.kind == "GunSkin" and "gun skin" or string.lower(item.kind)
				local itemName = string.find(string.lower(item.name), string.lower(item.kind == "GunSkin" and "skin" or item.kind), 1, true)
					and item.name or (item.name .. " " .. kindWord)
				announce(player, string.format("UNLOCKED: %s  (%s)", itemName, ProgressionData.CosmeticRequirement(entry)))
			end
		end
	end
	return granted
end

-- The Lifetime counters titles hang off only ever go up, so each is topped up to its true value.
local function topUp(player, data, stat, value)
	local current = data.Lifetime and data.Lifetime[stat]
	if current ~= nil and value > current then
		AchievementService.Track(player, stat, value - current)
	end
end

local function syncRankScore(player, data, progression)
	topUp(player, data, "rankScore",
		ProgressionData.RankScore(progression.prestige, ProgressionData.RankForXp(progression.xp)))
end

local function indexSize(progression)
	local count = 0
	for name in pairs(progression.index) do
		if BrainrotData.Get(name) then
			count += 1
		end
	end
	return count
end

--------------------------------------------------------------------------------
-- Migration
--------------------------------------------------------------------------------

-- Backfills a profile from before progression existed. `pendingPassXp` is pass XP already added to
-- the profile by the event being handled right now, which AddXp is about to count, so it's left out
-- here rather than counted twice.
function ProgressionService.Migrate(player, data, pendingPassXp)
	local progression = data.Progression
	if progression.v >= ProgressionData.Version then
		return false
	end
	progression.v = ProgressionData.Version

	local passXp = math.max(0, math.floor((data.Pass and data.Pass.xp or 0) - (pendingPassXp or 0)))
	local message = nil
	if progression.total == 0 and progression.xp == 0 and passXp > 0 then
		progression.total = passXp
		progression.xp = math.min(passXp, ProgressionData.PrestigeXp)
		local rank = ProgressionData.RankForXp(progression.xp)
		local cells = 0
		for reached = 2, rank do
			cells += ProgressionData.RankReward(reached, 0).cells
		end
		grantCells(progression, cells)
		progression.paidRank = rank -- the backfill just paid these ranks; they must never pay again
		if rank > 1 then
			message = string.format("ROT RANK unlocked: your Brainrot Pass XP puts you at rank %d.  +%s", rank, ProgressionData.Cells(cells))
		end
	end

	-- Anything with stars or companion XP was owned at some point, even if it's gone now.
	local seen = {}
	for _, name in ipairs(data.Brainrots or {}) do
		seen[name] = true
	end
	for _, field in ipairs({ "Stars", "CompanionXp" }) do
		for name, value in pairs(data[field] or {}) do
			if type(value) == "number" and value > 0 then
				seen[name] = true
			end
		end
	end
	for name in pairs(seen) do
		if BrainrotData.Get(name) and not progression.index[name] then
			progression.index[name] = ProgressionData.Recorded
		end
	end

	-- Migration runs as the profile loads, usually before the client's HUD is listening for toasts, so
	-- the news waits a few seconds rather than being fired into nothing.
	if message then
		task.delay(ProgressionService.WelcomeToastDelay, function()
			if player.Parent then
				announce(player, message)
			end
		end)
	end
	return true
end

-- The highest rank this profile has been paid for. Seen for the first time (a profile from before the
-- field, or a brand-new one), it's set to the rank the stored XP already reaches, so nobody is paid
-- retroactively when the curve is re-tuned and nobody is paid twice if it ever gets dearer.
local function ensurePaidRank(progression)
	if (progression.paidRank or 0) <= 0 then
		progression.paidRank = ProgressionData.RankForXp(progression.xp)
	end
	return progression.paidRank
end

-- The profile and its progression, migrated, or nil while it's still loading.
local function profileFor(player, pendingPassXp)
	local data = PlayerData.Get(player)
	local progression = data and data.Progression
	if type(progression) ~= "table" then
		return nil
	end
	ProgressionService.Migrate(player, data, pendingPassXp)
	ensurePaidRank(progression)
	return data, progression
end

--------------------------------------------------------------------------------
-- Rot Rank
--------------------------------------------------------------------------------

-- Adds Rot Rank XP and pays everything it unlocks. Doesn't touch the Brainrot Pass.
function ProgressionService.AddXp(player, amount, pendingPassXp)
	if type(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return
	end
	local data, progression = profileFor(player, pendingPassXp)
	if not data then
		return
	end
	amount = math.floor(math.min(amount, 1e9))

	progression.total = math.min(progression.total + amount, 1e15)
	local before = ProgressionData.RankForXp(progression.xp)
	local intoRank = math.min(amount, ProgressionData.PrestigeXp - progression.xp)
	progression.xp += intoRank
	local after = ProgressionData.RankForXp(progression.xp)

	-- Pay for ranks this profile hasn't been paid for yet, never merely for ranks crossed in this call:
	-- after a curve change the stored XP can already sit above `before`, and those ranks were never paid.
	local cells, crates = 0, {}
	for reached = math.max(before, progression.paidRank) + 1, after do
		local reward = ProgressionData.RankReward(reached, progression.prestige)
		cells += reward.cells
		if reward.crate and CrateService.Give(player, reward.crate, 1) then
			table.insert(crates, reward.crate)
		end
	end
	progression.paidRank = math.max(progression.paidRank, after)

	-- XP past MaxRank banks toward Overflow payouts instead of vanishing.
	local overflows = 0
	local spill = amount - intoRank
	if spill > 0 and after >= ProgressionData.MaxRank then
		progression.over = math.min(progression.over + spill, ProgressionData.OverflowXp * 1000)
		while progression.over >= ProgressionData.OverflowXp do
			progression.over -= ProgressionData.OverflowXp
			cells += ProgressionData.OverflowReward(progression.prestige)
			overflows += 1
		end
	end
	grantCells(progression, cells)

	-- State first, then the news. The toast used to go first, so anything that made it throw (it fires a
	-- remote at the player) left the Cells paid but the nameplate rank, the title counters and the
	-- client's copy all stale. tools/progression_runtime_probe.lua caught exactly that in a live server.
	if after > before then
		syncAttributes(player, progression)
		syncRankScore(player, data, progression)
	end
	if cells > 0 or after > before then
		schedulePush(player)
	end

	if after > before then
		local extra = #crates > 0 and ("  +1 " .. table.concat(crates, " Crate  +1 ") .. " Crate") or ""
		announce(player, string.format("ROT RANK %d!  +%s%s", after, ProgressionData.Cells(cells), extra))
		if after >= ProgressionData.MaxRank and progression.prestige < ProgressionData.MaxPrestige then
			announce(player, "Rot Rank 100 — you can PRESTIGE from the Pass tab's Rank page.")
		end
	elseif overflows > 0 then
		announce(player, string.format("OVERFLOW!  +%s", ProgressionData.Cells(cells)))
	end
end

-- BattlePassService.OnXp: the pass has already added `amount`.
function ProgressionService.OnPassXp(player, amount)
	ProgressionService.AddXp(player, amount, amount)
end

-- `expected` is the prestige the player saw when they confirmed. A mismatch means it already
-- happened (a double-click, two menus), so this one is refused instead of resetting them twice.
function ProgressionService.Prestige(player, expected)
	local data, progression = profileFor(player)
	if not data then
		return false, "Profile still loading."
	end
	if expected ~= progression.prestige then
		return false, string.format("You're already Prestige %d — that went through.", progression.prestige)
	end
	if progression.prestige >= ProgressionData.MaxPrestige then
		return false, "You're at the highest prestige there is."
	end
	if ProgressionData.RankForXp(progression.xp) < ProgressionData.MaxRank then
		return false, string.format("Reach Rot Rank %d to prestige.", ProgressionData.MaxRank)
	end

	progression.prestige += 1
	progression.xp = 0
	-- The new climb pays its ranks again from the bottom.
	progression.paidRank = 1
	local cells = grantCells(progression, ProgressionData.PrestigeReward(progression.prestige).cells)
	local info = ProgressionData.PrestigeInfo(progression.prestige)

	syncAttributes(player, progression)
	syncRankScore(player, data, progression)
	syncCosmetics(player, data, progression)
	pushNow(player)

	if progression.prestige >= SHOUT_PRESTIGE then
		for _, other in ipairs(Players:GetPlayers()) do
			if other ~= player then
				announce(other, string.format("%s reached PRESTIGE %d (%s)!", player.DisplayName, progression.prestige, info.name))
			end
		end
	end
	return true, string.format("PRESTIGE %d — %s!  Rot Rank starts again at 1, and rank rewards pay %d%% more Brain Cells.  +%s",
		progression.prestige, info.name, math.floor((ProgressionData.PrestigeMultiplier(progression.prestige) - 1) * 100 + 0.5),
		ProgressionData.Cells(cells))
end

--------------------------------------------------------------------------------
-- Mastery
--------------------------------------------------------------------------------

-- MatchService.OnKillCredited: a credited elimination. Only real players with a real gun earn
-- mastery; companions, barrels and mines don't count, and neither do bots.
function ProgressionService.OnKillCredited(killer, victim, weaponId)
	if not Combatants.IsPlayer(killer) or type(weaponId) ~= "string" or not WeaponData.Get(weaponId) then
		return
	end
	local data, progression = profileFor(killer)
	if not data then
		return
	end

	local mastery = progression.mastery
	if mastery[weaponId] == nil then
		local count = 0
		for _ in pairs(mastery) do
			count += 1
		end
		if count >= 128 then
			return
		end
	end

	local gain = Combatants.IsBot(victim) and ProgressionData.KillPoints.bot or ProgressionData.KillPoints.player
	local before = mastery[weaponId] or 0
	local after = math.min(before + gain, ProgressionData.MasteryPointCap)
	mastery[weaponId] = after

	local fromTier, toTier = ProgressionData.MasteryTier(before), ProgressionData.MasteryTier(after)
	if toTier == fromTier then
		schedulePush(killer)
		return
	end

	local gun = WeaponData.Get(weaponId).name
	local cells, xp = 0, 0
	for tier = fromTier + 1, toTier do
		local info = ProgressionData.MasteryTiers[tier]
		cells += info.cells
		xp += info.xp
		if tier == ProgressionData.MasteredTier then
			AchievementService.Track(killer, "mastered", 1)
		end
		if tier == #ProgressionData.MasteryTiers then
			AchievementService.Track(killer, "rotmasters", 1)
		end
	end
	grantCells(progression, cells)
	local reached = ProgressionData.MasteryTiers[toTier]
	local tiers = matchTiers[killer]
	if not tiers then
		tiers = {}
		matchTiers[killer] = tiers
	end
	if #tiers < 8 then
		table.insert(tiers, { gun = gun, tier = reached.name })
	end
	ProgressionService.AddXp(killer, xp)
	syncCosmetics(killer, data, progression)
	schedulePush(killer)
	announce(killer, string.format("MASTERY: %s is %s!  +%s  +%s Rank XP", gun, string.upper(reached.name), ProgressionData.Cells(cells), ProgressionData.Commas(xp)))
end

--------------------------------------------------------------------------------
-- Rot Index
--------------------------------------------------------------------------------

-- Writes down every brainrot the player owns that the Index hasn't seen. `quiet` skips the toast
-- (used on join, where the backfill has its own). `earnedName`, when the caller knows a brainrot just
-- came from play (a crate pull, a Cell Shop buy), turns a Purchased entry for it into a claimable one.
function ProgressionService.RecordIndex(player, quiet, earnedName)
	local data, progression = profileFor(player)
	if not data then
		return 0
	end
	local found = 0
	for _, name in ipairs(data.Brainrots) do
		if not progression.index[name] and BrainrotData.Get(name) then
			progression.index[name] = ProgressionData.Recorded
			found += 1
		end
	end
	if type(earnedName) == "string" and progression.index[earnedName] == ProgressionData.Purchased then
		progression.index[earnedName] = ProgressionData.Recorded
		found += 1
	end
	topUp(player, data, "discovered", indexSize(progression))
	if found > 0 then
		schedulePush(player)
		if not quiet then
			announce(player, string.format("ROT INDEX: %d new %s — claim Brain Cells on the Pass tab's Index page.",
				found, plural(found, "discovery", "discoveries")))
		end
	end
	return found
end

-- A brainrot just bought with Robux (the "Brainrot" grant handler in Bootstrap, right after the grant,
-- before anything else can scan the collection). If the Index hasn't seen it, it's logged as
-- Purchased: shown, never paid. One already found in play is left as it is.
function ProgressionService.RecordPurchased(player, name)
	local data = PlayerData.Get(player)
	local progression = data and data.Progression
	if type(progression) ~= "table" or type(name) ~= "string" or not BrainrotData.Get(name) then
		return false
	end
	-- Whether the entry was there BEFORE migrating. A receipt can land before the join hook on a profile
	-- from before progression, and Migrate backfills from data.Brainrots, which already holds this copy,
	-- so it would record the purchase as found in play. Overwrite what Migrate just made, unless the
	-- player also owns an older copy of it (then the older one really was found in play).
	local existed = progression.index[name] ~= nil
	ProgressionService.Migrate(player, data)
	if existed then
		return false
	end
	local ownedBefore = RewardService.CountOf(data, name) > 1 or (data.Stars and (data.Stars[name] or 0) > 0)
		or (data.CompanionXp and (data.CompanionXp[name] or 0) > 0)
	if progression.index[name] == ProgressionData.Recorded and ownedBefore then
		return false
	end
	progression.index[name] = ProgressionData.Purchased
	topUp(player, data, "discovered", indexSize(progression))
	schedulePush(player)
	return true
end

-- TradeService.OnTradeMoved: the brainrots have just changed hands and nothing has yielded yet. For
-- each species a player received that the giver's Index only has as Purchased, the receiver (if they've
-- never seen it) logs it as Purchased too, rather than as found in play. Yield-free.
function ProgressionService.OnTradeMoved(playerA, playerB, offerA, offerB)
	local function carry(giver, receiver, offer)
		local giverData, receiverData = PlayerData.Get(giver), PlayerData.Get(receiver)
		local giverIndex = giverData and type(giverData.Progression) == "table" and giverData.Progression.index
		if not giverIndex or not receiverData or type(receiverData.Progression) ~= "table" or type(offer) ~= "table" then
			return
		end
		-- No Migrate here: its backfill would record the copies that just arrived as found in play. A
		-- Purchased entry written now survives a later Migrate, which only fills empty entries.
		local receiverIndex = receiverData.Progression.index
		for _, name in ipairs(offer) do
			if BrainrotData.Get(name) then
				-- The giver owned it, so it's theirs in the Index even if no scan had written it down yet
				-- (a Daily Spin prize from the menu, say); after this trade no scan ever would. Purchases
				-- are always written at once, so an empty entry means it was found in play.
				if giverIndex[name] == nil then
					giverIndex[name] = ProgressionData.Recorded
				end
				if giverIndex[name] == ProgressionData.Purchased and receiverIndex[name] == nil then
					receiverIndex[name] = ProgressionData.Purchased
				end
			end
		end
	end
	carry(playerA, playerB, offerA)
	carry(playerB, playerA, offerB)
end

-- Claims one discovery by name, or every unclaimed one when `name` is nil. Pays each discovery's
-- Cells and any rarity page that the claim completes.
function ProgressionService.ClaimIndex(player, name)
	local data, progression = profileFor(player)
	if not data then
		return false, "Profile still loading."
	end
	ProgressionService.RecordIndex(player, true)

	local toClaim = {}
	if name ~= nil then
		local def = type(name) == "string" and #name <= 64 and BrainrotData.Get(name)
		if not def then
			return false, "No such brainrot."
		end
		local state = progression.index[name]
		if state == ProgressionData.Claimed then
			return false, name .. " is already claimed."
		elseif state == ProgressionData.Purchased then
			return false, name .. " was bought with Robux, so it pays no Brain Cells. Pull it from a crate or the Cell Shop to claim it."
		elseif state ~= ProgressionData.Recorded then
			return false, "Find " .. name .. " first."
		end
		table.insert(toClaim, def)
	else
		for entry, state in pairs(progression.index) do
			local def = state == ProgressionData.Recorded and BrainrotData.Get(entry)
			if def then
				table.insert(toClaim, def)
			end
		end
		if #toClaim == 0 then
			return false, "Nothing new to claim."
		end
	end

	-- Everything's validated; from here it only writes.
	local cells = 0
	for _, def in ipairs(toClaim) do
		progression.index[def.name] = ProgressionData.Claimed
		cells += ProgressionData.DiscoverCells[def.rarity] or 0
	end
	local pages = {}
	local counts = ProgressionData.IndexCounts(progression.index)
	for _, rarity in ipairs(Rarity.Order) do
		local count = counts[rarity]
		if not progression.pages[rarity] and count.total > 0 and count.claimed >= count.total then
			progression.pages[rarity] = true
			cells += ProgressionData.PageBonus[rarity] or 0
			table.insert(pages, rarity)
		end
	end
	grantCells(progression, cells)
	pushNow(player)

	local message = #toClaim == 1
		and string.format("Claimed %s.  +%s", toClaim[1].name, ProgressionData.Cells(cells))
		or string.format("Claimed %d discoveries.  +%s", #toClaim, ProgressionData.Cells(cells))
	if #pages > 0 then
		message ..= string.format("  (%s %s complete!)", table.concat(pages, ", "), plural(#pages, "page"))
	end
	return true, message
end

--------------------------------------------------------------------------------
-- Cell Shop
--------------------------------------------------------------------------------

-- Buys one of today's offers. The server works out today and today's rotation itself; `clientDay`
-- is only compared, so a menu left open over midnight is told the shop changed instead of buying
-- something that's gone. `companion` names who a Companion Snack feeds (the equipped one if nil).
-- The third return is true when a companion's XP changed, so the caller can refresh it.
function ProgressionService.BuyOffer(player, offerId, clientDay, companion)
	local data, progression = profileFor(player)
	if not data then
		return false, "Profile still loading."
	end
	if type(offerId) ~= "string" or #offerId > 16 then
		return false, "No such offer."
	end

	-- The permanent cosmetic listings: no day, no daily limit, one each for good.
	local listing = ProgressionData.FindCosmeticOffer(offerId)
	if listing then
		local item = CosmeticData.Get(listing.id)
		if not item or not item.rankOnly or not listing.cells then
			return false, "That offer isn't available."
		end
		if data.Cosmetics.owned[listing.id] then
			return false, "You already own " .. item.name .. "."
		end
		if progression.cells < listing.cells then
			return false, string.format("Need %s more.", ProgressionData.Cells(listing.cells - progression.cells))
		end
		progression.cells -= listing.cells
		data.Cosmetics.owned[listing.id] = true
		pushNow(player)
		return true, string.format("Unlocked %s for %s. Equip it from the Cosmetics tab.", item.name, ProgressionData.Cells(listing.cells))
	end

	local today = ProgressionData.Day(os.time())
	if clientDay ~= today then
		-- The menu is showing yesterday's shop: send today's so the page redraws.
		pushNow(player)
		return false, "The Cell Shop just restocked — take another look."
	end
	local offer = ProgressionData.FindOffer(today, offerId)
	if not offer then
		return false, "No such offer."
	end

	local bought = progression.shop.day == today and (progression.shop.bought[offerId] or 0) or 0
	if bought >= offer.limit then
		return false, "Sold out until tomorrow."
	end
	if progression.cells < offer.price then
		return false, string.format("Need %s more.", ProgressionData.Cells(offer.price - progression.cells))
	end

	local message, fed = nil, false
	if offer.kind == "Brainrot" then
		local def = offer.brainrot and BrainrotData.Get(offer.brainrot)
		if not def or Rarity.IsAtLeast(def.rarity, ProgressionData.ShopRarityCeiling) then
			return false, "That offer isn't available."
		end
		if not RewardService.GiveBrainrot(player, def.name) then
			return false, "Couldn't buy that — nothing was spent."
		end
		message = string.format("Bought %s (%s) for %s.", def.name, def.rarity, ProgressionData.Cells(offer.price))
	elseif offer.kind == "Snack" then
		local name = companion
		if name == nil then
			name = data.Companion
		end
		if type(name) ~= "string" or #name > 64 or not BrainrotData.Get(name) then
			return false, "Equip a companion first — the snack feeds the one following you."
		end
		if not table.find(data.Brainrots, name) then
			return false, "You don't own " .. name .. "."
		end
		local cap = (BrainrotData.MaxLevel - 1) * BrainrotData.XpPerLevel
		local xp = data.CompanionXp[name] or 0
		if xp >= cap then
			return false, name .. " is already max level."
		end
		local before = BrainrotData.LevelForXp(xp)
		data.CompanionXp[name] = math.min(cap, xp + offer.xp)
		local after = BrainrotData.LevelForXp(data.CompanionXp[name])
		fed = true
		message = after > before
			and string.format("%s ate the snack and reached level %d!", name, after)
			or string.format("%s ate the snack.  +%d companion XP", name, data.CompanionXp[name] - xp)
	else
		return false, "No such offer."
	end

	progression.cells -= offer.price
	if progression.shop.day ~= today then
		progression.shop.day = today
		progression.shop.bought = {}
	end
	progression.shop.bought[offerId] = bought + 1

	if offer.kind == "Brainrot" then
		-- Bought with Brain Cells counts as found in play.
		ProgressionService.RecordIndex(player, true, offer.brainrot)
		RewardService.CheckCollections(player)
	end
	pushNow(player)
	return true, message, fed
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

-- After the profile loads: migrate, record the Index, and put rank and prestige on the player for
-- nameplates.
function ProgressionService.OnProfileLoaded(player)
	local data, progression = profileFor(player)
	if not data then
		return
	end
	ProgressionService.RecordIndex(player, true)
	syncAttributes(player, progression)
	syncRankScore(player, data, progression)
	-- The mastery title counters are topped up from the mastery map itself, so they can't drift.
	local mastered, rotmasters = ProgressionData.MasterySummary(progression.mastery), 0
	for _, points in pairs(progression.mastery) do
		if ProgressionData.MasteryTier(points) >= #ProgressionData.MasteryTiers then
			rotmasters += 1
		end
	end
	topUp(player, data, "mastered", mastered)
	topUp(player, data, "rotmasters", rotmasters)
	-- Prestige and mastery cosmetics already earned (including before they existed) are handed over.
	-- Quietly: this runs as the profile loads, before the HUD listens, so one summary follows later.
	local granted = syncCosmetics(player, data, progression, true)
	if granted > 0 then
		task.delay(ProgressionService.WelcomeToastDelay, function()
			if player.Parent then
				announce(player, string.format("UNLOCKED %d rank reward%s. Find them under YOUR COSMETICS.", granted, granted == 1 and "" or "s"))
			end
		end)
	end
end

-- MatchService.OnMatchStart: remember where everyone stands, for MatchSummary. `players` defaults to
-- everyone in the server (the probe passes its stand-ins).
function ProgressionService.BeginMatch(players)
	table.clear(matchStart)
	table.clear(matchTiers)
	for _, player in ipairs(players or Players:GetPlayers()) do
		local data, progression = profileFor(player)
		if data then
			matchStart[player] = {
				rank = ProgressionData.RankForXp(progression.xp),
				prestige = progression.prestige,
				total = progression.total,
				cellsEarned = progression.cellsEarned,
			}
		end
	end
end

-- What this match did for a player's progression, for the results card, or nil if they weren't
-- around when it began. Called after placement rewards, so their XP is in it.
function ProgressionService.MatchSummary(player)
	local start = matchStart[player]
	local data = PlayerData.Get(player)
	local progression = data and data.Progression
	if not start or type(progression) ~= "table" then
		return nil
	end
	local rank, into, need = ProgressionData.RankProgress(progression.xp)
	return {
		rankFrom = start.rank,
		prestigeFrom = start.prestige,
		rank = rank,
		prestige = progression.prestige,
		xp = math.max(0, progression.total - start.total),
		cells = math.max(0, progression.cellsEarned - start.cellsEarned),
		xpInto = into,
		xpNeed = need,
		tiers = matchTiers[player] or {},
	}
end

function ProgressionService.Start()
	Players.PlayerRemoving:Connect(function(player)
		lastCall[player] = nil
		pushPending[player] = nil
		matchStart[player] = nil
		matchTiers[player] = nil
	end)
end

return ProgressionService
