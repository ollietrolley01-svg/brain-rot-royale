-- The team picker's rules, and nothing else: who may join which side, where the players who never
-- picked go, and how the bots split. Pure and total -- no services, no Instances, no clock -- so the
-- server (ServerScriptService/Modules/TeamPicker) enforces exactly what the client draws, and
-- tools/team_picker_check.py can run every rule without a Studio window.
--
-- THE BALANCE RULE. A side may hold at most HumanCap(H) = ceil(H / 2) of the H humans in the match.
-- Every human who does not pick is dealt onto the side with fewer humans when the window closes
-- (Resolve), so the final split can never differ by more than one human, however the picks went:
--   * friends and parties can all pick the same side as long as it has room under the cap;
--   * once one side is at the cap, the only way in is the other side, or AUTO.
-- The cap is on HUMANS. Bots fill both sides to the match's size afterwards (Sizes), so a side with
-- fewer humans is never a side with fewer bodies.

local TeamPickerRules = {}

-- What a pick of "no preference" is sent as.
TeamPickerRules.Auto = 0

-- The most humans one side may hold.
function TeamPickerRules.HumanCap(humanCount)
	return math.ceil(math.max(tonumber(humanCount) or 0, 0) / 2)
end

-- How many humans have picked each side. `picks` is token -> 1 | 2 (anything else is "auto").
function TeamPickerRules.Counts(picks)
	local counts = { 0, 0 }
	for _, team in pairs(picks or {}) do
		if team == 1 or team == 2 then
			counts[team] += 1
		end
	end
	return counts
end

-- May `token` move to `team`? Returns ok, reason ("bad team" | "full"). AUTO is always allowed, and
-- so is a pick of the side you are already on.
function TeamPickerRules.CanPick(picks, humanCount, token, team)
	if team == TeamPickerRules.Auto then
		return true
	end
	if team ~= 1 and team ~= 2 then
		return false, "bad team"
	end
	if picks[token] == team then
		return true
	end
	local counts = TeamPickerRules.Counts(picks)
	if counts[team] + 1 > TeamPickerRules.HumanCap(humanCount) then
		return false, "full"
	end
	return true
end

-- Every human's side once the window closes. `order` is the humans in match order; `picks` is what
-- they chose. The ones who chose nothing are dealt, in order, onto the side with fewer humans; a tie
-- goes to `firstTie` and then alternates, so an odd number of undecided players still balances.
-- Returns token -> team, and the final { humans on 1, humans on 2 }.
function TeamPickerRules.Resolve(order, picks, firstTie)
	local out, counts = {}, { 0, 0 }
	for _, token in ipairs(order or {}) do
		local team = picks and picks[token]
		if team == 1 or team == 2 then
			out[token] = team
			counts[team] += 1
		end
	end
	local tie = (firstTie == 2) and 2 or 1
	for _, token in ipairs(order or {}) do
		if not out[token] then
			local team
			if counts[1] < counts[2] then
				team = 1
			elseif counts[2] < counts[1] then
				team = 2
			else
				team = tie
				tie = (tie == 1) and 2 or 1
			end
			out[token] = team
			counts[team] += 1
		end
	end
	return out, counts
end

-- The two sides' sizes once bots fill the match to `total` bodies, given the final human split: the
-- side with more humans takes the odd slot, and a side never shrinks below its own humans (a match
-- with no bots is all humans). Returns size1, size2, bots1, bots2.
function TeamPickerRules.Sizes(total, humans1, humans2)
	total = math.max(tonumber(total) or 0, humans1 + humans2)
	local big = math.ceil(total / 2)
	local small = total - big
	local size1, size2
	if humans1 >= humans2 then
		size1, size2 = big, small
	else
		size1, size2 = small, big
	end
	size1, size2 = math.max(size1, humans1), math.max(size2, humans2)
	return size1, size2, size1 - humans1, size2 - humans2
end

-- After a player leaves, the cap can drop under a side's picks (3 humans, 2 of them on Ember, and the
-- third leaves: the cap is now 1, and Ember holds 2).
-- Returns the tokens whose picks must go back to AUTO, newest pick first, so the side is back under
-- the cap. `pickedAt` is token -> the order the pick was made in.
function TeamPickerRules.Overflow(picks, humanCount, pickedAt)
	local cap = TeamPickerRules.HumanCap(humanCount)
	local out = {}
	for team = 1, 2 do
		local members = {}
		for token, side in pairs(picks) do
			if side == team then
				table.insert(members, token)
			end
		end
		if #members > cap then
			table.sort(members, function(a, b)
				return (pickedAt[a] or 0) > (pickedAt[b] or 0)
			end)
			for i = 1, #members - cap do
				table.insert(out, members[i])
			end
		end
	end
	return out
end

-- Which modes show the picker: every mode that splits players into sides, and never the battle royale.
function TeamPickerRules.ShowsFor(mode)
	return type(mode) == "table" and mode.teams == true and mode.id ~= "BattleRoyale"
end

return TeamPickerRules
