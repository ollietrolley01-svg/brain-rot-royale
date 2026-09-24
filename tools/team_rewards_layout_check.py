"""The results card with the team modes' reward breakdown, built for real and measured at every screen size.

    python3 tools/team_rewards_layout_check.py            the check, then the planted faults
    python3 tools/team_rewards_layout_check.py --no-plants

Runs the REAL StarterPlayerScripts/ResultsScreen.client.lua (with the real UiKit, Rarity and GameModes)
under tools/menu_mocks.lua, the layout engine tools/menu_screens_check.py uses, and fires MatchResults at
it the way MatchService does. The team payload is the worst case the server can send: the lines come from
the REAL RewardService.TeamBreakdown (run through tools/team_rewards_check.py's world) with every cap hit,
MVP, and the 2x SahurCoins line, so the card is as tall as it can ever be; a long MVP pair; a crate. A
battle royale payload is drawn too, so the team changes are seen not to move it.

At each size (the HUD check's seven, the menu check's small phone, and a 640x360 phone on its side):
  fits       the card, at the scale ResultsScreen's own fitScale picked, fits the screen both ways, and
             that scale is at least FIT_FLOOR (0.5): fitScale clamps at 0.45, so a card that needs less
             spills off a phone, and "it fits" alone would pass right up to that edge
  lines      the breakdown draws one cell per line the server sent, each naming the line and what it paid
  inside     no breakdown text is wider than its box, names included (a truncated name hides its count;
             text width estimated at 0.55 x TextSize, as the
             menu check does)

Not modelled (menu_mocks.lua): UIScale is not applied by the engine, so "fits" multiplies the card's laid
out size by the scale the script set; fonts are estimated. The look is for a render: see the report.
"""
import os
import sys

from lupa import LuaRuntime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import menu_screens_check as menu  # noqa: E402
import team_rewards_check as rewards  # noqa: E402

# The smallest scale the card may need. ResultsScreen's fitScale clamps at 0.45 and a card that needs less
# spills off the screen; 0.5 keeps a margin, and keeps 13 px text above 6 px on the smallest phone.
FIT_FLOOR = 0.5

SIZES = [
    ("desktop 1920x1080", 1920, 1080),
    ("desktop 1366x768", 1366, 768),
    ("tablet 1024x768", 1024, 768),
    ("tablet upright 768x1024", 768, 1024),
    ("phone 844x390", 844, 390),
    ("phone upright 390x844", 390, 844),
    ("small phone upright 375x667", 375, 667),
    ("phone-small 320x640", 320, 640),
    ("phone on its side 640x360", 640, 360),
]


def worst_lines(overrides=None):
    """The longest breakdown the real TeamBreakdown makes: every line, every cap, MVP, plus the 2x line."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    sources = {name: rewards.luau_to_lua((overrides or {}).get(path, rewards.read(path)))
               for name, path in rewards.FILES.items()}
    world = lua.execute(rewards.WORLD, lua.table_from(sources), 4)
    lines, coins, xp, crate, bonus = lua.execute(r"""
        local W = ...
        local lines, coins, xp, _, bonusCrate, bonusCoins = W.RewardService.TeamBreakdown({ playerKills = 99,
            botKills = 99, assists = 99, revenges = 99, streakCoins = 9999, captures = 99, holdSeconds = 9999,
            defends = 99, activeSamples = 32, mvp = true, firstWin = true, winStreak = 9,
            unlock = "TeamCommanderAura", unlockName = "Commander Aura" }, "win", 1)
        table.insert(lines, { id = "coinPass", label = "2x SahurCoins", coins = coins, xp = 0 })
        return lines, coins * 2, xp, bonusCrate, bonusCoins
    """, world)
    return [dict(line.items()) for line in lines.values()], coins, xp, crate, bonus


DRAW = r"""
local M, lines, coins, xp, width, height, teamMode, FIT_FLOOR, bonusCrate, bonusCoins = ...
local out = { failures = {}, cells = 0, labels = 0 }
M.setViewport(width, height)
local payload
if teamMode then
	local list = {}
	for i = 1, #lines do list[i] = lines[i] end
	payload = {
		rank = 1, total = 30, mode = "KingOfTheHill", kills = 99,
		tally = { damage = 12345, chests = 3, items = 4 },
		combat = { shots = 300, hits = 150, headshots = 40, longestKill = 180, damageTaken = 900 },
		modeResults = { scores = { 250, 249 }, teams = { "Ember Squad", "Teal Crew" }, winner = 1, target = 250,
			mvps = { { team = 1, name = "SuperLongDisplayName_1234" }, { team = 2, name = "AnotherVeryLongName_99" } } },
		reward = { rank = 1, crate = "Rare", coins = coins, xp = xp, outcome = "win", lines = list, mvp = true,
			bonusCrate = bonusCrate, bonusCoins = bonusCoins },
		progression = { xp = xp, rank = 12, rankFrom = 11, prestige = 0, prestigeFrom = 0, cells = 40 },
	}
else
	payload = {
		rank = 3, total = 50, mode = "BattleRoyale", kills = 7, winnerName = "SomebodyElse",
		tally = { damage = 2345, chests = 9, items = 5, supply = 1, bounties = 1 },
		combat = { shots = 200, hits = 90, headshots = 12, longestKill = 140, damageTaken = 600 },
		companionDamage = 300, eggsFound = 1, eggsTotal = 5,
		reward = { rank = 3, crate = "Epic", coins = 1200, xp = 550 },
		progression = { xp = 800, rank = 12, rankFrom = 11, prestige = 0, prestigeFrom = 0, cells = 40 },
	}
end
M.remotes.MatchResults.OnClientEvent:Fire(payload)
local gui = M.playerGui:FindFirstChild("BrrResults")
local card, scale
for _, child in ipairs(gui:GetChildren()) do
	if child:FindFirstChildOfClass("UIListLayout") and child:FindFirstChildOfClass("UIScale") then
		card = child
		scale = child:FindFirstChildOfClass("UIScale").Scale
	end
end
if not card then
	table.insert(out.failures, "no results card drawn")
	return out
end
local size = M.absSize(card)
out.w, out.h, out.scale = size.X, size.Y, scale
if scale < FIT_FLOOR - 1e-9 then
	table.insert(out.failures, string.format("card %dx%d needs scale %.3f, under the %.2f floor", size.X, size.Y, scale, FIT_FLOOR))
end
if size.X * scale > width + 0.5 or size.Y * scale > height + 0.5 then
	table.insert(out.failures, string.format("card %dx%d at scale %.2f is %dx%d on a %dx%d screen",
		size.X, size.Y, scale, size.X * scale, size.Y * scale, width, height))
end
local breakdown = card:FindFirstChild("Breakdown")
if teamMode then
	if not breakdown then
		table.insert(out.failures, "team card has no breakdown")
		return out
	end
	local cells = {}
	for _, cell in ipairs(breakdown:GetChildren()) do
		if cell:IsA("Frame") then table.insert(cells, cell) end
	end
	table.sort(cells, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
	out.cells = #cells
	if #cells ~= #lines then
		table.insert(out.failures, string.format("breakdown drew %d cells for %d lines", #cells, #lines))
	end
	for i, cell in ipairs(cells) do
		local line = lines[i]
		local texts = {}
		for _, labelInst in ipairs(cell:GetChildren()) do
			if labelInst:IsA("TextLabel") then
				table.insert(texts, labelInst)
				out.labels = out.labels + 1
				local bounds = M.textBounds(labelInst)
				local box = M.absSize(labelInst)
				if bounds.X > box.X + 0.5 then
					table.insert(out.failures, string.format("'%s' is %d wide in a %d box", labelInst.Text, bounds.X, box.X))
				end
			end
		end
		local joined = ""
		for _, t in ipairs(texts) do joined = joined .. " | " .. t.Text end
		if line and (not joined:find(line.label, 1, true)) then
			table.insert(out.failures, "cell " .. i .. " does not name '" .. line.label .. "': " .. joined)
		end
		if line and line.coins > 0 and not joined:find("+", 1, true) then
			table.insert(out.failures, "cell " .. i .. " does not say what it paid: " .. joined)
		end
	end
	-- The TEAM BONUS chip, with its total, and the first win's crate.
	local seen = {}
	for _, inst in ipairs(card:GetDescendants()) do
		if inst:IsA("TextLabel") then seen[inst.Text] = true end
	end
	local want = "TEAM BONUS +" .. M.requireClient("UiKit").formatNumber(bonusCoins)
	if not seen[want] then table.insert(out.failures, "no '" .. want .. "' chip") end
	if not seen["+1 " .. string.upper(bonusCrate) .. " CRATE"] then table.insert(out.failures, "no first-win crate chip") end
elseif breakdown then
	table.insert(out.failures, "battle royale card drew a team breakdown")
end
return out
"""


def run(overrides=None):
    overrides = overrides or {}
    lines, coins, xp, bonus_crate, bonus_coins = worst_lines(overrides)
    failures, report = [], []
    for team in (True, False):
        for name, width, height in SIZES:
            lua = LuaRuntime(unpack_returned_tuples=True)
            mocks = lua.execute(menu.read("tools/menu_mocks.lua"))

            def get_source(path):
                return menu.luau_to_lua(overrides.get(path, menu.read(path)))
            M = lua.execute(menu.DRIVER, mocks, get_source, lua.table_from({}))
            lua.execute("local M = ... M.setup({ 'Rarity', 'Remotes', 'GameModes', 'CrateModels' }, { 'UiKit', 'Sfx' }, {})", M)
            M.runClient("ResultsScreen")
            table = lua.table_from([lua.table_from(line) for line in lines])
            out = lua.execute(DRAW, M, table, coins, xp, width, height, team, FIT_FLOOR, bonus_crate, bonus_coins)
            got = list(out.failures.values())
            failures += [f"{'team' if team else 'BR'} {name}: {g}" for g in got]
            warnings = [w for w in M.warnings.values()]
            failures += [f"{'team' if team else 'BR'} {name}: {w}" for w in warnings]
            report.append(f"  {'team' if team else 'BR  '} {name:28} card {out.w:4.0f}x{out.h:4.0f} at x{out.scale:.2f}"
                          f" -> {out.w * out.scale:4.0f}x{out.h * out.scale:4.0f}" + (f", {out.cells} lines, {out.labels} texts measured" if team else ""))
    return failures, report, len(lines)


RESULTS = "StarterPlayerScripts/ResultsScreen.client.lua"
PLANTS = [
    ("breakdown rows 30 px tall (fits, phone)",
     {RESULTS: menu.read(RESULTS).replace("local BREAKDOWN_ROW, BREAKDOWN_MAX, BREAKDOWN_PAID = 18, 16, 112",
                                          "local BREAKDOWN_ROW, BREAKDOWN_MAX, BREAKDOWN_PAID = 30, 16, 112")}),
    ("stat tiles kept in a team mode (fits, phone)",
     {RESULTS: menu.read(RESULTS).replace("\tif teamMode then\n\t\tlocal parts = {}", "\tif false then\n\t\tlocal parts = {}")}),
    ("TEAM BONUS chip dropped (bonus)",
     {RESULTS: menu.read(RESULTS).replace("if (tonumber(reward.bonusCoins) or 0) > 0 then", "if false then")}),
    ("breakdown stops at five lines (lines)",
     {RESULTS: menu.read(RESULTS).replace("local BREAKDOWN_ROW, BREAKDOWN_MAX, BREAKDOWN_PAID = 18, 16, 112",
                                          "local BREAKDOWN_ROW, BREAKDOWN_MAX, BREAKDOWN_PAID = 18, 5, 112")}),
    ("paid column too narrow for '+1.0K  ·  60 XP' (inside)",
     {RESULTS: menu.read(RESULTS).replace("local BREAKDOWN_ROW, BREAKDOWN_MAX, BREAKDOWN_PAID = 18, 16, 112",
                                          "local BREAKDOWN_ROW, BREAKDOWN_MAX, BREAKDOWN_PAID = 18, 16, 60")}),
    ("names squeezed by a 200 px paid column (inside)",
     {RESULTS: menu.read(RESULTS).replace("local BREAKDOWN_ROW, BREAKDOWN_MAX, BREAKDOWN_PAID = 18, 16, 112",
                                          "local BREAKDOWN_ROW, BREAKDOWN_MAX, BREAKDOWN_PAID = 18, 16, 200")}),
]


def main():
    failures, report, count = run()
    print(f"team_rewards_layout_check: {len(SIZES)} sizes x (team, battle royale), worst-case breakdown of {count} lines")
    for line in report:
        print(line)
    for f in failures:
        print("  FAIL: " + f)
    print(f"  {len(failures)} failure(s)")
    ok = not failures
    if "--no-plants" not in sys.argv:
        caught = 0
        for label, override in PLANTS:
            planted, _, _ = run(override)
            caught += bool(planted)
            print(f"  {'CAUGHT' if planted else 'MISSED'}: {label}" + (f" ({planted[0]})" if planted else ""))
        print(f"team_rewards_layout_check plant: {caught} of {len(PLANTS)} planted faults caught")
        ok = ok and caught == len(PLANTS)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
