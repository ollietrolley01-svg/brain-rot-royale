-- Coins, XP, brainrot grants, placement payouts, and selling.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local QuestData = require(Shared:WaitForChild("QuestData"))
local ShopRotation = require(Shared:WaitForChild("ShopRotation"))

local BattlePassService = require(script.Parent:WaitForChild("BattlePassService"))
local CrateService = require(script.Parent:WaitForChild("CrateService"))
local Monetization = require(script.Parent:WaitForChild("Monetization"))
local GlobalBoardService = require(script.Parent:WaitForChild("GlobalBoardService"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local QuestService = require(script.Parent:WaitForChild("QuestService"))
local StateSync = require(script.Parent:WaitForChild("StateSync"))

local RewardService = {}

-- Placement coins are scaled by this for the match; a High Stakes event raises it.
RewardService.PlacementMultiplier = 1

-- Coins earned by playing, through Monetization.EarnCoins so the 2x SahurCoins pass applies to
-- every source alike. `source` "sell" marks coins from selling brainrots (see GamepassConfig).
function RewardService.AddCoins(player, amount, source)
	return Monetization.EarnCoins(player, amount, source)
end

function RewardService.GiveBrainrot(player, name)
	local data = PlayerData.Get(player)
	if not data then
		return false
	end
	if not BrainrotData.Get(name) then
		return false
	end
	table.insert(data.Brainrots, name)
	return true
end

-- Bot kills pay noticeably less than real ones, so a lobby full of backfill can't be farmed
-- as hard as a lobby full of people.
-- `scale` (optional, default 1) is the team modes' reduced kill rate (MatchConfig.TeamModeRewards).
function RewardService.AwardKill(player, wasBot, scale)
	local data = PlayerData.Get(player)
	if not data then
		return
	end
	scale = scale or 1

	data.Stats.kills += 1
	RewardService.AddCoins(player, math.floor((wasBot and MatchConfig.CoinsPerBotKill or MatchConfig.CoinsPerKill) * scale + 0.5))
	BattlePassService.AddXp(player, math.floor((wasBot and MatchConfig.XpPerBotKill or MatchConfig.XpPerKill) * scale + 0.5))
	StateSync.Push(player)
	QuestService.Progress(player, "kills", 1)
end

-- Coins for something that just happened, with a line saying what. `reason` goes in brackets after
-- the amount, so it wants to be a SHORT NOUN PHRASE -- "Gold Rush", "bounty on Steve", "found the
-- Sahur statue". A whole sentence in there reads as an afterthought to the coins, which inverts
-- which of the two the player cares about; announce the event yourself and pass a short reason.
--
-- Note the message only goes out when coins actually landed. That is right for a reward line, and it
-- is the reason an event worth announcing should not rely on this function to announce it: a player
-- whose profile has not loaded gets silence.
function RewardService.AwardBonusCoins(player, amount, reason)
	local granted = RewardService.AddCoins(player, amount)
	if granted > 0 then
		StateSync.Notify(player, string.format("+%d SahurCoins (%s)", granted, reason))
		StateSync.Push(player)
	end
end

-- A number in [0, 1) for the win's Mythic Crate roll. tools/mythic_crate_check.py seeds it.
RewardService.Roll = math.random

-- The results card's line for a win's Mythic Crate roll (MatchConfig `mythicChance`): the chance, read from
-- the field the roll used, and whether it dropped. `crate` is set only when it did; the payouts give exactly
-- that, so the card's line and the crate given can't disagree. The team card lists it as a breakdown line
-- (`label`, and `note` where a line's pay goes; the label is kept short to fit its cell); the battle royale
-- card, which has no breakdown, shows `chip`.
function RewardService.MythicLine(chance, won)
	local odds = MatchConfig.ChanceText(chance)
	return {
		id = "mythic",
		label = string.format("Mythic %s chance", odds),
		note = won and "+1 CRATE" or "not this time",
		chip = won and string.format("+1 MYTHIC CRATE (%s CHANCE)", odds)
			or string.format("MYTHIC CRATE %s CHANCE: NOT THIS TIME", odds),
		crate = won and "Mythic" or nil,
		coins = 0,
		xp = 0,
	}
end

-- Placement rewards do not stack: one crate, from the bracket you landed in. Open it from
-- the menu to find out what's inside. A bracket with `mythicChance` (the win) also rolls for a Mythic Crate.
function RewardService.AwardPlacement(player, rank)
	local data = PlayerData.Get(player)
	if not data then
		return nil
	end

	data.Stats.matches += 1
	if rank == 1 then
		data.Stats.wins += 1
		GlobalBoardService.SubmitWins(player, data.Stats.wins)
	end

	QuestService.Progress(player, "matches", 1)
	if rank <= 10 then
		QuestService.Progress(player, "top10", 1)
	end
	if rank == 1 then
		QuestService.Progress(player, "wins", 1)
	end

	local bracket = MatchConfig.GetBracket(rank)
	if not bracket then
		StateSync.Push(player)
		return nil
	end

	CrateService.Give(player, bracket.crate, 1)
	local mythic = nil
	if bracket.mythicChance then
		mythic = RewardService.MythicLine(bracket.mythicChance, RewardService.Roll() < bracket.mythicChance)
		if mythic.crate then
			CrateService.Give(player, mythic.crate, 1)
		end
	end

	local coins = RewardService.AddCoins(player, math.floor(bracket.coins * RewardService.PlacementMultiplier))
	BattlePassService.AddXp(player, bracket.xp)
	StateSync.Push(player)

	return {
		rank = rank,
		crate = bracket.crate,
		coins = coins,
		xp = bracket.xp,
		mythic = mythic,
	}
end

-- The team modes' itemised payout (MatchConfig.TeamModeRewards). Pure: reads `summary` -- what one player
-- did this match, from GameMode's ledger -- and returns the lines the results card lists, their coin and
-- XP totals, and the crate. Nothing is paid here, so a check can run it on any summary it likes.
--
-- summary = { playerKills, botKills, assists, revenges, streakCoins, captures, holdSeconds, defends,
--             activeSamples, mvp (bool), afk (bool),
--             and the TEAM BONUS inputs AwardTeamResult adds: firstWin (bool), winStreak (n), unlock (id),
--             and mythic (bool), whether a win's Mythic Crate roll came up };
--             every field optional.
-- Each line is { id, label, count?, coins, xp, bonus? }. `bonus` marks the TEAM BONUS lines -- what only the
-- team modes pay (MVP, first win of the day, win streak, a team cosmetic) -- which the card highlights and
-- totals. Lines that pay nothing are left out, except the result and an unlock.
-- Returns lines, coins, xp, crate, bonusCrate (the first win's), bonusCoins (the TEAM BONUS total).
local RESULT_LABEL = { win = "Victory", draw = "Draw", loss = "Defeat" }

function RewardService.TeamBreakdown(summary, outcome, multiplier)
	local rules = MatchConfig.TeamModeRewards or {}
	summary = summary or {}
	multiplier = multiplier or 1
	local lines = {}
	local function n(value)
		return math.max(0, math.floor(tonumber(value) or 0))
	end
	local function add(id, label, count, coins, xp, bonus)
		coins, xp = math.max(0, math.floor(coins)), math.max(0, math.floor(xp))
		if id == "result" or id == "unlock" or coins > 0 or xp > 0 then
			table.insert(lines, { id = id, label = label, count = count, coins = coins, xp = xp, bonus = bonus or nil })
		end
	end

	-- Idle for most of the match: the afk line and nothing else. No crate either.
	if summary.afk then
		local afk = rules.afk or {}
		add("result", "Away from keyboard", nil, afk.coins or 0, afk.xp or 0)
		return lines, lines[1].coins, lines[1].xp, nil, nil, 0
	end

	local result = rules[outcome] or rules.loss or {}
	add("result", RESULT_LABEL[outcome] or "Defeat", nil, (result.coins or 0) * multiplier, result.xp or 0)
	-- A win's Mythic Crate roll, shown on every win whether it dropped or not: the odds are part of the pay.
	if outcome == "win" and rules.mythicChance then
		table.insert(lines, RewardService.MythicLine(rules.mythicChance, summary.mythic == true))
	end

	-- Kills at the battle royale's own rate, a real player's first (they pay more), then bots, to the cap.
	local cap = (rules.kill and rules.kill.cap) or 15
	local playerKills = math.min(n(summary.playerKills), cap)
	local botKills = math.min(n(summary.botKills), cap - playerKills)
	add("kills", "Eliminations", playerKills + botKills,
		playerKills * MatchConfig.CoinsPerKill + botKills * MatchConfig.CoinsPerBotKill,
		playerKills * MatchConfig.XpPerKill + botKills * MatchConfig.XpPerBotKill)

	local function counted(id, label, value, rule)
		if not rule then
			return
		end
		local count = math.min(n(value), rule.cap or math.huge)
		add(id, label, count, count * (rule.coins or 0), count * (rule.xp or 0))
	end
	counted("assists", "Assists", summary.assists, rules.assist)
	if rules.streak then
		add("streaks", "Multi-kills", nil, math.min(n(summary.streakCoins), rules.streak.cap or math.huge), 0)
	end
	counted("revenge", "Revenge", summary.revenges, rules.revenge)
	counted("captures", "Captures", summary.captures, rules.capture)
	if rules.hold then
		local seconds = math.min(n(summary.holdSeconds), rules.hold.capSeconds or math.huge)
		add("hold", "On objective", seconds, seconds * (rules.hold.coinsPerSecond or 0), seconds * (rules.hold.xpPerSecond or 0))
	end
	counted("defends", "Defends", summary.defends, rules.defend)
	local participation = rules.participation
	if participation then
		local minutes = n(summary.activeSamples) * (participation.sampleSeconds or 15) / 60
		add("time", "Time played", math.floor(minutes), minutes * (participation.coinsPerMinute or 0), minutes * (participation.xpPerMinute or 0))
	end

	-- TEAM BONUS: what the battle royale does not pay at all.
	local bonus = rules.bonus or {}
	if summary.mvp and rules.mvp then
		add("mvp", "Team MVP", nil, rules.mvp.coins or 0, rules.mvp.xp or 0, true)
	end
	local bonusCrate = nil
	if summary.firstWin and bonus.firstWin then
		add("firstWin", "First win today", nil, bonus.firstWin.coins or 0, bonus.firstWin.xp or 0, true)
		bonusCrate = bonus.firstWin.crate
	end
	local streak = n(summary.winStreak)
	if streak >= 2 and bonus.winStreak then
		local steps = math.min(streak - 1, bonus.winStreak.maxSteps or 4)
		add("winStreak", "Win streak", streak, steps * (bonus.winStreak.coins or 0), steps * (bonus.winStreak.xp or 0), true)
	end
	if type(summary.unlock) == "string" then
		add("unlock", summary.unlockName or summary.unlock, nil, 0, 0, true)
	end

	local coins, xp, bonusCoins = 0, 0, 0
	for _, line in ipairs(lines) do
		coins += line.coins
		xp += line.xp
		if line.bonus then
			bonusCoins += line.coins
		end
	end
	return lines, coins, xp, result.crate, bonusCrate, bonusCoins
end

-- A player's team-mode record: lifetime team wins and matches (the milestones that unlock the team
-- cosmetics) and the current run of consecutive team wins. Kept on the profile as `TeamRewards`, made here
-- the first time it is needed. PERSISTENCE NEEDS PlayerData TO KNOW THE FIELD (its reconcile keeps only what
-- defaultData declares): until it does, the record lasts one visit. Cosmetics already unlocked are in
-- Cosmetics.owned and persist either way, so nothing earned is ever taken back.
function RewardService.TeamRecord(data)
	local record = data.TeamRewards
	if type(record) ~= "table" then
		record = {}
		data.TeamRewards = record
	end
	for _, key in ipairs({ "wins", "matches", "streak" }) do
		if type(record[key]) ~= "number" then
			record[key] = 0
		end
	end
	return record
end

-- The first team win of the UTC day is marked in the day's quest progress under this key, not a quest id:
-- QuestData.Ensure clears that table at midnight, so the marker is saved today (Quests.progress keeps any
-- string -> number) and gone tomorrow with no timestamp to compare. The menu only reads progress by quest id.
RewardService.FirstTeamWinKey = "teamFirstWin"

-- What a match was worth before any cap: how GameMode ranks a team's MVP. The same rates TeamBreakdown
-- pays, so the MVP is whoever the card would have paid most for what they did.
function RewardService.TeamPerformanceValue(summary)
	local rules = MatchConfig.TeamModeRewards or {}
	summary = summary or {}
	local function v(value, rate)
		return (tonumber(value) or 0) * (rate or 0)
	end
	return v(summary.playerKills, MatchConfig.CoinsPerKill) + v(summary.botKills, MatchConfig.CoinsPerBotKill)
		+ v(summary.assists, rules.assist and rules.assist.coins) + (tonumber(summary.streakCoins) or 0)
		+ v(summary.revenges, rules.revenge and rules.revenge.coins) + v(summary.captures, rules.capture and rules.capture.coins)
		+ v(summary.holdSeconds, rules.hold and rules.hold.coinsPerSecond) + v(summary.defends, rules.defend and rules.defend.coins)
end

-- The end-of-match payout for a team mode. `outcome` is "win", "draw" or "loss"; `summary` is what the
-- player did (see TeamBreakdown). Counts the match played (Stats.matches, the matches quest) but never a
-- battle royale win. Returns the shape AwardPlacement does plus `lines`, the itemised breakdown the
-- results card lists; the lines always sum to `coins` and `xp` (a 2x SahurCoins pass is a line of its own).
function RewardService.AwardTeamResult(player, outcome, rank, summary)
	local data = PlayerData.Get(player)
	if not data then
		return nil
	end
	summary = summary or {}
	data.Stats.matches += 1
	QuestService.Progress(player, "matches", 1)

	-- TEAM BONUS state: first win of the day, the win streak, the milestone cosmetics. An idle player earns
	-- none of it, and breaks a streak.
	local rules = MatchConfig.TeamModeRewards or {}
	local bonus = rules.bonus or {}
	local record = RewardService.TeamRecord(data)
	summary = table.clone(summary)
	if summary.afk then
		record.streak = 0
	else
		record.matches += 1
		if outcome == "win" then
			record.wins += 1
			record.streak += 1
			summary.winStreak = record.streak
			summary.mythic = rules.mythicChance ~= nil and RewardService.Roll() < rules.mythicChance
			local quests = QuestData.Ensure(data.Quests, StateSync.CurrentDay())
			if not quests.progress[RewardService.FirstTeamWinKey] then
				quests.progress[RewardService.FirstTeamWinKey] = 1
				summary.firstWin = true
			end
		else
			record.streak = 0
		end
		for _, milestone in ipairs(bonus.milestones or {}) do
			local item = CosmeticData.Get(milestone.cosmetic)
			if item and record.wins >= milestone.wins and not data.Cosmetics.owned[milestone.cosmetic] then
				data.Cosmetics.owned[milestone.cosmetic] = true
				summary.unlock, summary.unlockName = milestone.cosmetic, item.name
				break
			end
		end
	end

	local lines, coins, xp, crate, bonusCrate, bonusCoins = RewardService.TeamBreakdown(summary, outcome, RewardService.PlacementMultiplier)
	if crate then
		CrateService.Give(player, crate, 1)
	end
	if bonusCrate then
		CrateService.Give(player, bonusCrate, 1)
	end
	for _, line in ipairs(lines) do
		if line.id == "mythic" and line.crate then
			CrateService.Give(player, line.crate, 1)
		end
	end
	local granted = RewardService.AddCoins(player, coins)
	if granted > coins then
		table.insert(lines, { id = "coinPass", label = "2x SahurCoins", coins = granted - coins, xp = 0 })
	end
	BattlePassService.AddXp(player, xp)

	-- The team-mode quests (QuestData: teamMatches, teamWins, assists, captures, mvp). Not for an idle
	-- player: a quest is for playing.
	if not summary.afk then
		QuestService.Progress(player, "teamMatches", 1)
		if outcome == "win" then
			QuestService.Progress(player, "teamWins", 1)
		end
		QuestService.Progress(player, "assists", math.floor(tonumber(summary.assists) or 0))
		QuestService.Progress(player, "captures", math.floor(tonumber(summary.captures) or 0))
		if summary.mvp then
			QuestService.Progress(player, "mvp", 1)
		end
	end
	StateSync.Push(player)
	return {
		rank = rank,
		crate = crate,
		coins = granted,
		xp = xp,
		outcome = outcome,
		lines = lines,
		mvp = summary.mvp == true,
		afk = summary.afk == true,
		bonusCrate = bonusCrate,
		bonusCoins = bonusCoins,
		winStreak = summary.winStreak,
	}
end

-- One-time bonus for owning every brainrot of a rarity at once. Paid the first time the set is
-- complete and never again, even if copies are later sold or traded away.
RewardService.CollectionBonus = BrainrotData.CollectionBonus

function RewardService.CheckCollections(player)
	local data = PlayerData.Get(player)
	if not data then
		return false
	end

	local owned = {}
	for _, name in ipairs(data.Brainrots) do
		owned[name] = true
	end

	local completed = false
	for rarity, bonus in pairs(RewardService.CollectionBonus) do
		if not data.Collections[rarity] then
			local set = BrainrotData.OfRarity(rarity)
			local complete = #set > 0
			for _, def in ipairs(set) do
				if not owned[def.name] then
					complete = false
					break
				end
			end
			if complete then
				data.Collections[rarity] = true
				completed = true
				local granted = RewardService.AddCoins(player, bonus)
				StateSync.Notify(player, string.format("%s set complete! +%d SahurCoins", rarity, granted))
				QuestService.Progress(player, "sets", 1)
			end
		end
	end

	if completed then
		StateSync.Push(player)
	end
	return completed
end

-- The brainrot that follows you around and fights for you. Equipping the one already equipped
-- (or nil) takes it off.
function RewardService.SetCompanion(player, name)
	local data = PlayerData.Get(player)
	if not data then
		return false, "Profile still loading."
	end

	if name == nil or data.Companion == name then
		data.Companion = nil
		StateSync.Push(player)
		return true, "Companion unequipped."
	end

	if not BrainrotData.Get(name) then
		return false, "No such brainrot."
	end
	if not table.find(data.Brainrots, name) then
		return false, "You don't own that."
	end

	data.Companion = name
	StateSync.Push(player)
	return true, name .. " will follow you now."
end

function RewardService.SetShowcase(player, name)
	local data = PlayerData.Get(player)
	if not data then
		return false, "Profile still loading."
	end

	if name == nil then
		data.Showcase = nil
		StateSync.Push(player)
		return true, "Showcase cleared."
	end

	if not BrainrotData.Get(name) then
		return false, "No such brainrot."
	end
	if not table.find(data.Brainrots, name) then
		return false, "You don't own that."
	end

	data.Showcase = name
	StateSync.Push(player)
	return true, "Showing off " .. name .. "."
end

function RewardService.CountOf(data, name)
	local count = 0
	for _, owned in ipairs(data.Brainrots) do
		if owned == name then
			count += 1
		end
	end
	return count
end

-- Set by Bootstrap to TradeService.InSession. Merging and selling are refused while a trade is
-- open: the trade re-checks ownership when it executes, so nothing could be duplicated, but taking
-- away copies you'd offered would quietly turn a trade you were about to confirm into a
-- cancellation. Selling mid-trade was also how a merged brainrot's last copy got traded away (the
-- spare sold after the offer), leaving its stars on a profile with no copy to carry them.
local TRADING_MESSAGE = "Finish or cancel your trade first."
RewardService.IsTrading = function()
	return false
end

-- Fuses spare copies of a brainrot into the one you keep for its next star (BrainrotData
-- merging). The spares are used up; the kept copy, and every later copy of that brainrot, fights
-- with the bonus.
--
-- `fromStars` is the star count the player saw when they confirmed. If it no longer matches, the
-- merge already happened (a double-click, or two menus) and this one is refused rather than
-- spending a second batch of copies nobody asked to spend. It's optional for server callers.
--
-- Atomic: everything is validated, then the new collection is built aside and checked, and only
-- then is anything written. Nothing here yields, so no other request can run in between.
function RewardService.MergeBrainrot(player, name, fromStars)
	local data = PlayerData.Get(player)
	if not data then
		return false, "Profile still loading."
	end

	local def = BrainrotData.Get(name)
	if not def then
		return false, "No such brainrot."
	end

	if RewardService.IsTrading(player) then
		return false, "Finish or cancel your trade before merging."
	end

	local stars = BrainrotData.ClampStars(data.Stars[name])
	if fromStars ~= nil and fromStars ~= stars then
		return false, string.format("%s is already at %d star%s — that merge went through.", name, stars, stars == 1 and "" or "s")
	end

	local cost = BrainrotData.MergeCost(stars)
	if not cost then
		return false, string.format("%s is already fully merged.", name)
	end

	local owned = RewardService.CountOf(data, name)
	if owned < 1 then
		return false, "You don't own that."
	end
	local spare = owned - 1
	if spare < cost then
		return false, string.format("Merging %s to %d stars takes %d spare cop%s — you have %d.",
			name, stars + 1, cost, cost == 1 and "y" or "ies", spare)
	end

	-- The spares come off the end of the list, so the oldest copy is the one that stays.
	local kept, removed = {}, 0
	for index = #data.Brainrots, 1, -1 do
		local entry = data.Brainrots[index]
		if entry == name and removed < cost then
			removed += 1
		else
			table.insert(kept, entry)
		end
	end
	if removed ~= cost or #kept ~= #data.Brainrots - cost then
		return false, "Couldn't merge that — nothing was changed."
	end
	-- `kept` was filled back to front.
	local reordered = {}
	for index = #kept, 1, -1 do
		table.insert(reordered, kept[index])
	end

	data.Brainrots = reordered
	data.Stars[name] = stars + 1
	StateSync.Push(player)
	return true, string.format("Merged %s to %s!  +%d%% damage and health", name,
		BrainrotData.StarText(stars + 1), math.floor((BrainrotData.StarBonus(stars + 1) - 1) * 100 + 0.5)), stars + 1
end

-- Anything the profile POINTS AT that is no longer in the collection. Two things do: the companion
-- following the player around, and the brainrot on their lobby podium.
--
-- The podium is the one that leaks outward. A showcase left pointing at a sold brainrot keeps
-- rendering on the podium, stays in other players' showcase and trade lists, and persists in the
-- saved profile indefinitely -- so it is not "a stale field", it is other people seeing something
-- the owner does not own. TradeService already clears both this way after a swap; selling is the
-- other path that can take the last copy, and SELL 1 has no confirmation step.
--
-- Returns whether the SHOWCASE changed, because that is the only one the caller has to tell the
-- world about (ShowcaseService.Refresh rebuilds every podium, so it is not run for nothing).
local function dropOrphanedDisplays(data)
	if data.Companion and not table.find(data.Brainrots, data.Companion) then
		data.Companion = nil
	end
	if data.Showcase and not table.find(data.Brainrots, data.Showcase) then
		data.Showcase = nil
		return true
	end
	return false
end

function RewardService.SellBrainrot(player, name)
	local data = PlayerData.Get(player)
	if not data then
		return false, "Profile still loading."
	end
	if RewardService.IsTrading(player) then
		return false, TRADING_MESSAGE
	end

	local def = BrainrotData.Get(name)
	if not def then
		return false, "No such brainrot."
	end

	local index = table.find(data.Brainrots, name)
	if not index then
		return false, "You don't own that."
	end
	-- Stars would survive the sale, but nothing to equip them on would, and SELL 1 has no
	-- confirmation step. TradeService refuses the last copy for the same reason.
	if (data.Stars[name] or 0) > 0 and RewardService.CountOf(data, name) <= 1 then
		return false, string.format("%s is merged (%s) — you can't sell your last copy.", name, BrainrotData.StarText(data.Stars[name]))
	end

	table.remove(data.Brainrots, index)
	-- Selling your last copy sends your companion home and takes it off your podium.
	local showcaseChanged = dropOrphanedDisplays(data)
	local coins = RewardService.AddCoins(player, def.coinValue, "sell")

	StateSync.Push(player)
	return true, string.format("Sold %s for %d SahurCoins.", name, coins), showcaseChanged
end

function RewardService.SellAllOfRarity(player, rarity)
	local data = PlayerData.Get(player)
	if not data then
		return false, "Profile still loading."
	end
	if RewardService.IsTrading(player) then
		return false, TRADING_MESSAGE
	end

	-- One copy of every merged brainrot stays behind, for the same reason SELL 1 won't take it.
	local kept, total, sold, spared = {}, 0, 0, {}
	for _, name in ipairs(data.Brainrots) do
		local def = BrainrotData.Get(name)
		if def and def.rarity == rarity and (data.Stars[name] or 0) > 0 and not spared[name] then
			spared[name] = true
			table.insert(kept, name)
		elseif def and def.rarity == rarity then
			total += def.coinValue
			sold += 1
		else
			table.insert(kept, name)
		end
	end

	if sold == 0 then
		return false, "No " .. rarity .. " brainrots to sell" .. (next(spared) and " (merged ones keep their last copy)." or ".")
	end

	data.Brainrots = kept
	local showcaseChanged = dropOrphanedDisplays(data)
	local coins = RewardService.AddCoins(player, total, "sell")

	StateSync.Push(player)
	return true, string.format("Sold %d %s brainrots for %d SahurCoins.%s", sold, rarity, coins,
		next(spared) and " Kept one copy of each merged one." or ""), showcaseChanged
end

-- Sells every copy beyond the first of each brainrot, so a collector can cash in doubles without
-- touching the collection itself (and never the last copy of a companion or showcase pick).
function RewardService.SellDuplicates(player)
	local data = PlayerData.Get(player)
	if not data then
		return false, "Profile still loading."
	end
	if RewardService.IsTrading(player) then
		return false, TRADING_MESSAGE
	end

	local seen, kept, total, sold = {}, {}, 0, 0
	for _, name in ipairs(data.Brainrots) do
		local def = BrainrotData.Get(name)
		if def and seen[name] then
			total += def.coinValue
			sold += 1
		else
			seen[name] = true
			table.insert(kept, name)
		end
	end

	if sold == 0 then
		return false, "No duplicates to sell."
	end

	data.Brainrots = kept
	local coins = RewardService.AddCoins(player, total, "sell")
	StateSync.Push(player)
	return true, string.format("Sold %d duplicate%s for %d SahurCoins.", sold, sold == 1 and "" or "s", coins)
end

function RewardService.BuyCosmetic(player, cosmeticId)
	local item = CosmeticData.Get(cosmeticId)
	if not item then
		return false, "No such cosmetic."
	end

	local data = PlayerData.Get(player)
	if not data then
		return false, "Profile still loading."
	end

	if data.Cosmetics.owned[cosmeticId] then
		return false, "You already own that."
	end

	-- Crate exclusives have no price; the menu shows them as unbuyable, and this makes sure.
	if item.crateOnly or not item.price then
		return false, "That one only comes from crates."
	end

	if not ShopRotation.IsCosmeticInStock(cosmeticId) then
		return false, string.format("%s isn't in the shop right now. Stock changes in %s.", item.name, ShopRotation.FormatTimeLeft())
	end

	if data.SahurCoins < item.price then
		return false, string.format("Need %d more SahurCoins.", math.ceil(item.price - data.SahurCoins))
	end

	data.SahurCoins -= item.price
	data.Cosmetics.owned[cosmeticId] = true

	StateSync.Push(player)
	return true, "Unlocked " .. item.name .. "."
end

function RewardService.EquipCosmetic(player, cosmeticId)
	local data = PlayerData.Get(player)
	if not data then
		return false, "Profile still loading."
	end

	-- nil clears every cosmetic slot. (It used to clear only the gun skin, so an equipped aura
	-- could never be removed.)
	if cosmeticId == nil then
		data.Cosmetics.gunSkin = nil
		data.Cosmetics.aura = nil
		data.Cosmetics.accessory = nil
		data.Cosmetics.parachute = nil
		data.Cosmetics.killAnimation = nil
		StateSync.Push(player)
		return true, "Cosmetics removed."
	end

	local item = CosmeticData.Get(cosmeticId)
	if not item then
		return false, "No such cosmetic."
	end
	if not data.Cosmetics.owned[cosmeticId] then
		return false, "You don't own that."
	end

	local SLOT_FOR_KIND = {
		GunSkin = "gunSkin", Aura = "aura", Accessory = "accessory", Parachute = "parachute", KillAnimation = "killAnimation",
	}
	local slotKey = SLOT_FOR_KIND[item.kind]
	if not slotKey then
		return false, "That can't be equipped."
	end

	-- Equipping what's already equipped takes it off — the only way back to the default
	-- rarity colours, since the menu used to show a dead "EQUIPPED" button instead.
	if data.Cosmetics[slotKey] == cosmeticId then
		data.Cosmetics[slotKey] = nil
		StateSync.Push(player)
		return true, "Unequipped " .. item.name .. "."
	end

	data.Cosmetics[slotKey] = cosmeticId

	StateSync.Push(player)
	return true, "Equipped " .. item.name .. "."
end

return RewardService
