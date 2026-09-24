-- Daily quests and weekly challenges.
--
-- Three quests a day — one easy, one medium, one hard — and two challenges a week, the same for
-- everyone, rolled from the day or week number so every server agrees without talking. Progress
-- lives on the profile: dailies reset at midnight UTC, weeklies every seven days. A quest pays
-- coins and pass XP the moment it's done; finishing all three dailies pays a bonus crate on top,
-- and every weekly challenge pays a crate of its own.
--
-- `stat` is what QuestService counts. Where they come from:
--   kills     eliminations (players and bots)        matches   matches played
--   top10     top-10 finishes                        wins      wins
--   chests    chests opened                          items     heals, shields and items used
--   damage    damage dealt (shield counts)           crates    crates opened in the menu
--   supply    supply drops claimed                   obby      Cloud Climb clears
--   goals     goals scored on the lobby pitch        landmarkChests  chests opened inside a landmark
--   builds    portable defenses built (mines too)    barrels   explosive barrels you set off
--   vendor    Rot Vendor purchases                   hazardKills  eliminations by barrel or Rot Mine
-- The team modes (RewardService.AwardTeamResult, at the end of a Team Deathmatch or Objective Capture; not
-- counted for a player idle most of the match):
--   teamMatches  team matches played                 teamWins  team matches won
--   assists      assists                             captures  objectives captured (Objective Capture)
--   mvp          times the team's MVP
--
-- Titles use %d for the target; the ones without a number ignore it.

local QuestData = {}

QuestData.BonusCrate = "Epic"
QuestData.WeeklyCount = 2

QuestData.Pool = {
	easy = {
		{ id = "kills5", stat = "kills", target = 5, title = "Eliminate %d opponents", coins = 400, xp = 150 },
		{ id = "matches2", stat = "matches", target = 2, title = "Play %d matches", coins = 400, xp = 150 },
		{ id = "chests6", stat = "chests", target = 6, title = "Open %d chests", coins = 400, xp = 150 },
		{ id = "items6", stat = "items", target = 6, title = "Use %d heals, shields or items", coins = 400, xp = 150 },
		{ id = "damage800", stat = "damage", target = 800, title = "Deal %d damage", coins = 400, xp = 150 },
		{ id = "goals3", stat = "goals", target = 3, title = "Score %d goals on the lobby pitch", coins = 400, xp = 150 },
		{ id = "crates2", stat = "crates", target = 2, title = "Open %d crates", coins = 400, xp = 150 },
		{ id = "landmark3", stat = "landmarkChests", target = 3, title = "Open %d chests at landmarks", coins = 400, xp = 150 },
		{ id = "builds3", stat = "builds", target = 3, title = "Build %d portable defenses", coins = 400, xp = 150 },
		{ id = "barrels2", stat = "barrels", target = 2, title = "Blow up %d explosive barrels", coins = 400, xp = 150 },
		{ id = "vendor2", stat = "vendor", target = 2, title = "Buy %d things from a Rot Vendor", coins = 400, xp = 150 },
		{ id = "team2", stat = "teamMatches", target = 2, title = "Play %d team matches", coins = 400, xp = 150 },
	},
	medium = {
		{ id = "kills12", stat = "kills", target = 12, title = "Eliminate %d opponents", coins = 900, xp = 300 },
		{ id = "top10x2", stat = "top10", target = 2, title = "Finish in the top 10 %d times", coins = 900, xp = 300 },
		{ id = "chests15", stat = "chests", target = 15, title = "Open %d chests", coins = 900, xp = 300 },
		{ id = "items15", stat = "items", target = 15, title = "Use %d heals, shields or items", coins = 900, xp = 300 },
		{ id = "damage2500", stat = "damage", target = 2500, title = "Deal %d damage", coins = 900, xp = 300 },
		{ id = "matches4", stat = "matches", target = 4, title = "Play %d matches", coins = 900, xp = 300 },
		{ id = "supply1", stat = "supply", target = 1, title = "Claim a supply drop", coins = 900, xp = 300 },
		{ id = "obby1", stat = "obby", target = 1, title = "Clear the Cloud Climb", coins = 900, xp = 300 },
		{ id = "landmark8", stat = "landmarkChests", target = 8, title = "Open %d chests at landmarks", coins = 900, xp = 300 },
		{ id = "hazard2", stat = "hazardKills", target = 2, title = "Eliminate %d opponents with barrels or mines", coins = 900, xp = 300 },
		{ id = "barrels6", stat = "barrels", target = 6, title = "Blow up %d explosive barrels", coins = 900, xp = 300 },
		{ id = "assists6", stat = "assists", target = 6, title = "Get %d assists in team matches", coins = 900, xp = 300 },
		{ id = "captures3", stat = "captures", target = 3, title = "Capture %d objectives in Objective Capture", coins = 900, xp = 300 },
	},
	hard = {
		{ id = "win1", stat = "wins", target = 1, title = "Win a match", coins = 2000, xp = 600 },
		{ id = "kills25", stat = "kills", target = 25, title = "Eliminate %d opponents", coins = 2000, xp = 600 },
		{ id = "top10x4", stat = "top10", target = 4, title = "Finish in the top 10 %d times", coins = 2000, xp = 600 },
		{ id = "damage5000", stat = "damage", target = 5000, title = "Deal %d damage", coins = 2000, xp = 600 },
		{ id = "chests30", stat = "chests", target = 30, title = "Open %d chests", coins = 2000, xp = 600 },
		{ id = "obby3", stat = "obby", target = 3, title = "Clear the Cloud Climb %d times", coins = 2000, xp = 600 },
		{ id = "crates5", stat = "crates", target = 5, title = "Open %d crates", coins = 2000, xp = 600 },
		{ id = "hazard5", stat = "hazardKills", target = 5, title = "Eliminate %d opponents with barrels or mines", coins = 2000, xp = 600 },
		-- Three, where the battle royale's is one: a team match is won about half the time.
		{ id = "teamwins3", stat = "teamWins", target = 3, title = "Win %d team matches", coins = 2000, xp = 600 },
	},
}

-- Weekly challenges: the long grind. Each one pays a crate on top of coins and XP.
QuestData.WeeklyPool = {
	{ id = "w_wins3", stat = "wins", target = 3, title = "Win %d matches", coins = 6000, xp = 2000, crate = "Legendary" },
	{ id = "w_kills100", stat = "kills", target = 100, title = "Eliminate %d opponents", coins = 6000, xp = 2000, crate = "Legendary" },
	{ id = "w_top10x10", stat = "top10", target = 10, title = "Finish in the top 10 %d times", coins = 5000, xp = 1500, crate = "Epic" },
	{ id = "w_chests80", stat = "chests", target = 80, title = "Open %d chests", coins = 4000, xp = 1200, crate = "Epic" },
	{ id = "w_matches15", stat = "matches", target = 15, title = "Play %d matches", coins = 4000, xp = 1200, crate = "Epic" },
	{ id = "w_damage20000", stat = "damage", target = 20000, title = "Deal %d damage", coins = 5000, xp = 1500, crate = "Epic" },
	{ id = "w_obby7", stat = "obby", target = 7, title = "Clear the Cloud Climb %d times", coins = 3500, xp = 1000, crate = "Rare" },
	{ id = "w_crates12", stat = "crates", target = 12, title = "Open %d crates", coins = 4000, xp = 1200, crate = "Epic" },
	{ id = "w_goals15", stat = "goals", target = 15, title = "Score %d goals on the lobby pitch", coins = 3000, xp = 900, crate = "Rare" },
	{ id = "w_items60", stat = "items", target = 60, title = "Use %d heals, shields or items", coins = 4000, xp = 1200, crate = "Epic" },
	{ id = "w_hazard10", stat = "hazardKills", target = 10, title = "Eliminate %d opponents with barrels or mines", coins = 4000, xp = 1200, crate = "Epic" },
	{ id = "w_vendor12", stat = "vendor", target = 12, title = "Buy %d things from Rot Vendors", coins = 3000, xp = 900, crate = "Rare" },
	{ id = "w_teamwins10", stat = "teamWins", target = 10, title = "Win %d team matches", coins = 5000, xp = 1500, crate = "Epic" },
	{ id = "w_mvp3", stat = "mvp", target = 3, title = "Be your team's MVP %d times", coins = 5000, xp = 1500, crate = "Epic" },
}

QuestData.TierOrder = { "easy", "medium", "hard" }

for tier, list in pairs(QuestData.Pool) do
	for _, quest in ipairs(list) do
		quest.tier = tier
	end
end
for _, quest in ipairs(QuestData.WeeklyPool) do
	quest.tier = "weekly"
end

function QuestData.Title(quest)
	return string.format(quest.title, quest.target)
end

function QuestData.Day(now)
	return math.floor((now or os.time()) / 86400)
end

function QuestData.Week(now)
	return math.floor(QuestData.Day(now) / 7)
end

local cachedDay, cachedToday = nil, nil
local cachedWeek, cachedWeekly = nil, nil

-- The three quests for `day`, one per tier, drawn with a Random seeded from the day.
function QuestData.Today(day)
	if cachedDay == day then
		return cachedToday
	end
	local random = Random.new(day * 6151 + 7)
	local list = {}
	for _, tier in ipairs(QuestData.TierOrder) do
		local pool = QuestData.Pool[tier]
		table.insert(list, pool[random:NextInteger(1, #pool)])
	end
	cachedDay, cachedToday = day, list
	return list
end

-- The challenges for `week`, two different ones.
function QuestData.ThisWeek(week)
	if cachedWeek == week then
		return cachedWeekly
	end
	local random = Random.new(week * 9973 + 3)
	local pool = table.clone(QuestData.WeeklyPool)
	local list = {}
	for _ = 1, math.min(QuestData.WeeklyCount, #pool) do
		table.insert(list, table.remove(pool, random:NextInteger(1, #pool)))
	end
	cachedWeek, cachedWeekly = week, list
	return list
end

-- Rolls a profile's quest record over to `day` (and its week) if it's from an earlier one.
function QuestData.Ensure(quests, day)
	if quests.day ~= day then
		quests.day = day
		quests.progress = {}
		quests.done = {}
		quests.bonus = false
	end
	local week = math.floor(day / 7)
	if quests.week ~= week then
		quests.week = week
		quests.weekProgress = {}
		quests.weekDone = {}
	end
	return quests
end

local function describe(quest, progress, done)
	return {
		id = quest.id,
		tier = quest.tier,
		stat = quest.stat,
		title = QuestData.Title(quest),
		target = quest.target,
		progress = math.min(quest.target, progress or 0),
		done = done == true,
		coins = quest.coins,
		xp = quest.xp,
		crate = quest.crate,
	}
end

-- What the menu draws: every quest with its progress, the bonus state and the reset timers.
function QuestData.Snapshot(quests, day, now)
	QuestData.Ensure(quests, day)
	now = now or os.time()

	local list, doneCount = {}, 0
	for _, quest in ipairs(QuestData.Today(day)) do
		local done = quests.done[quest.id] == true
		if done then
			doneCount += 1
		end
		table.insert(list, describe(quest, quests.progress[quest.id], done))
	end

	local weekly = {}
	for _, quest in ipairs(QuestData.ThisWeek(quests.week)) do
		table.insert(weekly, describe(quest, quests.weekProgress[quest.id], quests.weekDone[quest.id]))
	end

	return {
		day = day,
		resetIn = math.max(0, (day + 1) * 86400 - now),
		list = list,
		doneCount = doneCount,
		total = #list,
		bonusClaimed = quests.bonus == true,
		bonusCrate = QuestData.BonusCrate,
		weekly = weekly,
		weekResetIn = math.max(0, (quests.week + 1) * 7 * 86400 - now),
	}
end

-- "5h 12m" (or "2d 5h") until the next set.
function QuestData.FormatReset(seconds)
	seconds = math.max(0, math.floor(seconds))
	if seconds >= 86400 then
		return string.format("%dd %dh", seconds // 86400, (seconds % 86400) // 3600)
	elseif seconds >= 3600 then
		return string.format("%dh %02dm", seconds // 3600, (seconds % 3600) // 60)
	end
	return string.format("%dm %02ds", seconds // 60, seconds % 60)
end

return QuestData
