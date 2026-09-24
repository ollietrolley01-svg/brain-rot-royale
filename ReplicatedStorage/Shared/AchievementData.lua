-- Achievements: lifetime milestones that pay coins once and unlock a title to wear on your
-- nameplate. Progress is read straight off the profile — `stat` names a counter in Stats (wins,
-- kills, matches) or Lifetime (everything else QuestService funnels through).

local AchievementData = {}

AchievementData.List = {
	{ id = "kill1", name = "First Blood", title = "Rookie", stat = "kills", target = 1, coins = 200,
		description = "Eliminate your first opponent." },
	{ id = "kill100", name = "Hundred Club", title = "Hunter", stat = "kills", target = 100, coins = 2000,
		description = "Eliminate 100 opponents." },
	{ id = "kill500", name = "Five Hundred", title = "Reaper", stat = "kills", target = 500, coins = 8000,
		description = "Eliminate 500 opponents." },
	{ id = "win1", name = "Last One Standing", title = "Winner", stat = "wins", target = 1, coins = 500,
		description = "Win a match." },
	{ id = "win10", name = "Ten Crowns", title = "Champion", stat = "wins", target = 10, coins = 5000,
		description = "Win 10 matches." },
	{ id = "win50", name = "Fifty Crowns", title = "Legend", stat = "wins", target = 50, coins = 25000,
		description = "Win 50 matches." },
	{ id = "match25", name = "Regular", title = "Regular", stat = "matches", target = 25, coins = 1000,
		description = "Play 25 matches." },
	{ id = "match200", name = "Veteran", title = "Veteran", stat = "matches", target = 200, coins = 10000,
		description = "Play 200 matches." },
	{ id = "top10x50", name = "Always There", title = "Consistent", stat = "top10", target = 50, coins = 3000,
		description = "Finish in the top 10 fifty times." },
	{ id = "chest100", name = "Looter", title = "Looter", stat = "chests", target = 100, coins = 2000,
		description = "Open 100 chests." },
	{ id = "landmark50", name = "Explorer", title = "Explorer", stat = "landmarkChests", target = 50, coins = 3000,
		description = "Open 50 chests at landmarks." },
	{ id = "build50", name = "Architect", title = "Architect", stat = "builds", target = 50, coins = 3000,
		description = "Build 50 portable defenses." },
	{ id = "damage50k", name = "Menace", title = "Menace", stat = "damage", target = 50000, coins = 6000,
		description = "Deal 50,000 damage." },
	{ id = "obby10", name = "Head For Heights", title = "Cloud Climber", stat = "obby", target = 10, coins = 3000,
		description = "Clear the Cloud Climb 10 times." },
	{ id = "goal25", name = "Top Scorer", title = "Striker", stat = "goals", target = 25, coins = 2000,
		description = "Score 25 goals on the lobby pitch." },
	{ id = "bounty10", name = "Wanted Dead", title = "Bounty Hunter", stat = "bounties", target = 10, coins = 4000,
		description = "Collect 10 bounties." },
	{ id = "crate20", name = "Crate Addict", title = "Crate Addict", stat = "crates", target = 20, coins = 2000,
		description = "Open 20 crates." },
	{ id = "quest30", name = "Grinder", title = "Grinder", stat = "questsDone", target = 30, coins = 5000,
		description = "Complete 30 quests or challenges." },
	{ id = "set1", name = "Full Set", title = "Collector", stat = "sets", target = 1, coins = 3000,
		description = "Own every brainrot of one rarity at once." },
	{ id = "set4", name = "Museum", title = "Curator", stat = "sets", target = 4, coins = 15000,
		description = "Complete four rarity sets." },
	{ id = "barrel50", name = "Powder Keg", title = "Demolitionist", stat = "barrels", target = 50, coins = 3000,
		description = "Blow up 50 explosive barrels." },
	{ id = "hazard25", name = "Booby Trapper", title = "Trapper", stat = "hazardKills", target = 25, coins = 4000,
		description = "Eliminate 25 opponents with explosive barrels or Rot Mines." },
	{ id = "vendor30", name = "Regular Customer", title = "Big Spender", stat = "vendor", target = 30, coins = 2500,
		description = "Buy 30 things from Rot Vendors." },
	{ id = "item150", name = "Well Stocked", title = "Stocked Up", stat = "items", target = 150, coins = 3000,
		description = "Use 150 heals, shields or items." },
	{ id = "supply10", name = "Drop Zone", title = "Air Support", stat = "supply", target = 10, coins = 4000,
		description = "Claim 10 supply drops." },

	-- Progression (ProgressionService). `rankScore` is prestige * 100 + Rot Rank, so 101 is the first
	-- prestige; `mastered` counts guns at Gold mastery or better.
	{ id = "rank25", name = "Quarter Rotten", title = "Rotting", stat = "rankScore", target = 25, coins = 1000,
		description = "Reach Rot Rank 25." },
	{ id = "rank50", name = "Half Gone", title = "Brain Drain", stat = "rankScore", target = 50, coins = 2500,
		description = "Reach Rot Rank 50." },
	{ id = "rank100", name = "Fully Rotted", title = "Fully Rotted", stat = "rankScore", target = 100, coins = 5000,
		description = "Reach Rot Rank 100." },
	{ id = "prestige1", name = "Born Again", title = "Reborn", stat = "rankScore", target = 101, coins = 5000,
		description = "Prestige for the first time." },
	{ id = "prestige5", name = "Rot Royalty", title = "Rot Royalty", stat = "rankScore", target = 501, coins = 9000,
		description = "Reach Prestige 5." },
	{ id = "prestige10", name = "Eternal Rot", title = "Rot Eternal", stat = "rankScore", target = 1001, coins = 25000,
		description = "Reach Prestige 10, the highest there is." },
	{ id = "mastered1", name = "Gun Nerd", title = "Gun Nerd", stat = "mastered", target = 1, coins = 1500,
		description = "Reach Gold mastery with any gun." },
	{ id = "mastered10", name = "Armory", title = "Armorer", stat = "mastered", target = 10, coins = 6000,
		description = "Reach Gold mastery with 10 different guns." },
	{ id = "rotmaster1", name = "Rotmaster", title = "Rotmaster", stat = "rotmasters", target = 1, coins = 8000,
		description = "Reach Rotmaster, the top mastery tier, with any gun." },
	{ id = "index60", name = "Field Notes", title = "Rotologist", stat = "discovered", target = 60, coins = 4000,
		description = "Discover 60 different brainrots in the Rot Index." },
	{ id = "index120", name = "Brainrotica", title = "Encyclopedic", stat = "discovered", target = 120, coins = 9000,
		description = "Discover 120 different brainrots in the Rot Index." },
}

-- Counters that live on the profile's Lifetime table (Stats holds wins, kills and matches).
AchievementData.LifetimeStats = {
	"top10", "chests", "items", "damage", "crates", "supply", "obby", "goals", "bounties", "questsDone", "sets",
	"landmarkChests", "builds", "barrels", "hazardKills", "vendor",
	"rankScore", "mastered", "rotmasters", "discovered",
}

local byId = {}
for _, achievement in ipairs(AchievementData.List) do
	byId[achievement.id] = achievement
end

function AchievementData.Get(id)
	return byId[id]
end

function AchievementData.Value(data, stat)
	if data.Stats and data.Stats[stat] then
		return data.Stats[stat]
	end
	return data.Lifetime and data.Lifetime[stat] or 0
end

-- For the menu: every achievement with progress and whether it's unlocked, plus the worn title.
-- The rank rows count in "rank score" (prestige × 100 + rank), a unit nothing else on screen uses:
-- a Rot Rank 37 player read "37 / 101" towards Born Again and "37 / 1,001" towards Eternal Rot. So
-- those rows say it in the Rank page's own words instead (#86). nil for every other stat, and the
-- menu falls back to the plain count.
function AchievementData.ProgressText(achievement, progress)
	if achievement.stat ~= "rankScore" then
		return nil
	end
	if achievement.target > 100 then
		return string.format("Prestige %d / %d", math.floor(progress / 100), math.floor(achievement.target / 100))
	end
	return string.format("Rank %d / %d", progress, achievement.target)
end

function AchievementData.Snapshot(data)
	local list = {}
	for _, achievement in ipairs(AchievementData.List) do
		local progress = math.min(achievement.target, AchievementData.Value(data, achievement.stat))
		table.insert(list, {
			progressText = AchievementData.ProgressText(achievement, progress),
			id = achievement.id,
			name = achievement.name,
			title = achievement.title,
			description = achievement.description,
			target = achievement.target,
			progress = progress,
			coins = achievement.coins,
			unlocked = data.Achievements[achievement.id] == true,
		})
	end
	return { list = list, title = data.Title }
end

return AchievementData
