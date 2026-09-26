"""A win's Mythic Crate roll (Task 24), run for real without Studio.

    python3 tools/mythic_crate_check.py .            the checks
    python3 tools/mythic_crate_check.py . --plant    the checks, then every planted fault (each must go red)

Runs the REAL ReplicatedStorage/Shared/MatchConfig.lua and ServerScriptService/Modules/RewardService.lua in
lupa, with the payout sinks mocked (CrateService.Give records every crate), and RewardService.Roll seeded, so
a run is repeatable. 100,000 of each:

  br win     AwardPlacement at rank 1: the Mythic Crate lands at the configured rate (within TOLERANCE), on
             top of the bracket's own crate every time; the crates given are exactly the card's (reward.mythic)
  br rank 2+ AwardPlacement at ranks 2-50: never a Mythic Crate, and no Mythic line on the card
  team win   AwardTeamResult "win": the same rate, the win's own crate every time, one "mythic" line on every
             card, and a crate given exactly when that line says it dropped
  team loss / draw / idle win   never a Mythic Crate, and no Mythic line
  shown      every Mythic label and chip the player sees carries the configured chance, formatted here in
             Python from the number read out of MatchConfig.lua's text, not through the game's own formatter;
             and the lobby tip (HudClient's NEW_PLAYER_TIPS block, run for real) says it too

Not covered: the card's drawing (tools/team_rewards_layout_check.py builds the real ResultsScreen with the
real TeamBreakdown lines) and anything a player sees in Studio.
"""
import math
import os
import re
import sys

from lupa import LuaRuntime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from team_rewards_check import luau_to_lua  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MC = "ReplicatedStorage/Shared/MatchConfig.lua"
RS = "ServerScriptService/Modules/RewardService.lua"
HUD = "StarterPlayerScripts/HudClient.client.lua"
N = 100000
SEED = 24
# 5 standard deviations of a 1% rate over 100,000 rolls is 0.16 points; a wrong rate (2x, or 0) is far past it.
SIGMAS = 5


def read(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as handle:
        return handle.read()


def configured(mc_text):
    """The two chances as written in MatchConfig.lua: (battle royale rank 1, team win)."""
    br = re.search(r"\{ maxRank = 1,[^}]*mythicChance = ([\d.]+)", mc_text)
    team = re.search(r"^\tmythicChance = ([\d.]+),", mc_text, re.M)
    return (float(br.group(1)) if br else None), (float(team.group(1)) if team else None)


def shown(chance):
    return f"{chance * 100:g}%"


WORLD = r"""
local sources, seed = ...
local W = { crates = {} }
function table.clone(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
math.randomseed(seed)
-- MatchConfig builds a few Roblox values at load; none of them matter here.
local function any() return {} end
Vector3 = { new = any }
CFrame = { new = any, Angles = any, lookAt = any }
Color3 = { fromRGB = any, new = any }
UDim2 = { fromOffset = any, fromScale = any, new = any }

local mocks = {}
mocks.BrainrotData = { CollectionBonus = {}, Get = function() return nil end }
mocks.CosmeticData = { Get = function() return nil end }
mocks.ShopRotation = {}
mocks.QuestData = { Ensure = function(q) q.progress = q.progress or {} return q end }
mocks.BattlePassService = { AddXp = function() end }
mocks.CrateService = { Give = function(p, crate, n) table.insert(W.crates, crate) return true end }
mocks.Monetization = { EarnCoins = function(p, amount) return amount end }
mocks.GlobalBoardService = { SubmitWins = function() end }
mocks.PlayerData = { Get = function(p) return p.data end, HasStore = function() return false end, CanSave = function() return true end }
mocks.QuestService = { Progress = function() end }
mocks.StateSync = { Notify = function() end, Push = function() end, CurrentDay = function() return 1 end }

local loaded = {}
local function folder()
	return { WaitForChild = function(_, name) return { __module = name } end }
end
local function load_(name)
	if loaded[name] then return loaded[name] end
	local module = mocks[name]
	if not module then
		module = assert(load(sources[name], "=" .. name))()
	end
	loaded[name] = module
	return module
end
require = function(marker) return load_(marker.__module) end
script = { Parent = folder() }
game = { GetService = function() return { WaitForChild = function() return folder() end } end }
W.MatchConfig = load_("MatchConfig")
W.RewardService = load_("RewardService")

function W.player()
	return { data = { Stats = { matches = 0, wins = 0 }, Quests = {}, Cosmetics = { owned = {} } } }
end
-- Runs `fn` and returns the crates it gave, as a list.
function W.given(fn)
	W.crates = {}
	local reward = fn()
	return reward, W.crates
end
return W
"""


def world(overrides):
    lua = LuaRuntime(unpack_returned_tuples=True)
    sources = {"MatchConfig": luau_to_lua(overrides.get(MC, read(MC))),
               "RewardService": luau_to_lua(overrides.get(RS, read(RS)))}
    return lua, lua.execute(WORLD, lua.table_from(sources), SEED)


def lines_of(reward):
    return [reward.lines[i] for i in range(1, len(reward.lines) + 1)] if reward and reward.lines else []


def crates_of(given):
    return [given[i] for i in range(1, len(given) + 1)]


def run(overrides=None):
    """Every check once. Returns (failures, report lines)."""
    overrides = overrides or {}
    failures, report = [], []
    br_chance, team_chance = configured(overrides.get(MC, read(MC)))
    if br_chance is None or team_chance is None:
        return [f"MatchConfig has no mythicChance (rank 1 {br_chance}, team {team_chance})"], report
    lua, W = world(overrides)
    RS_, MC_ = W.RewardService, W.MatchConfig

    def rate_ok(name, hits, chance):
        tol = SIGMAS * math.sqrt(chance * (1 - chance) / N)
        rate = hits / N
        ok = abs(rate - chance) <= tol
        report.append(f"  {name}: {hits} Mythic Crates in {N:,} = {rate * 100:.3f}% (configured {chance * 100:g}%, "
                      f"tolerance +-{tol * 100:.3f} points) {'ok' if ok else 'FAIL'}")
        if not ok:
            failures.append(f"{name}: Mythic rate {rate * 100:.3f}%, configured {chance * 100:g}%")

    def text_ok(name, text, chance):
        if shown(chance) not in str(text):
            failures.append(f"{name}: the player reads {text!r}, which doesn't carry the configured {shown(chance)}")
            return False
        return True

    # Battle royale, rank 1.
    player, mythics, bad_shown, mismatch, missing_base = W.player(), 0, 0, 0, 0
    samples = {}
    for _ in range(N):
        reward, given = W.given(lambda: RS_.AwardPlacement(player, 1))
        crates = crates_of(given)
        mythic = reward.mythic
        dropped = crates.count("Mythic")
        mythics += dropped
        missing_base += crates.count(reward.crate) != 1 or reward.crate != MC_.GetBracket(1).crate
        card = 1 if mythic is not None and mythic.crate == "Mythic" else 0
        mismatch += card != dropped
        if mythic is None:
            bad_shown += 1
            continue
        samples.setdefault(bool(card), mythic.chip)
        if shown(br_chance) not in str(mythic.chip) or shown(br_chance) not in str(mythic.label):
            bad_shown += 1
    rate_ok("battle royale win", mythics, br_chance)
    for won, chip in sorted(samples.items()):
        report.append(f"    card chip when it {'drops' if won else 'misses'}: {chip!r}")
        text_ok("battle royale chip", chip, br_chance)
    if bad_shown:
        failures.append(f"battle royale win: {bad_shown} cards without the configured {shown(br_chance)}")
    if mismatch:
        failures.append(f"battle royale win: {mismatch} cards disagree with the crates given")
    if missing_base:
        failures.append(f"battle royale win: {missing_base} wins without exactly one {MC_.GetBracket(1).crate} Crate")

    # Battle royale, every other rank.
    paid, lined = 0, 0
    for i in range(N):
        rank = 2 + i % 49
        reward, given = W.given(lambda: RS_.AwardPlacement(player, rank))
        paid += crates_of(given).count("Mythic")
        lined += reward is not None and reward.mythic is not None
    report.append(f"  battle royale ranks 2-50: {paid} Mythic Crates and {lined} Mythic lines in {N:,}")
    if paid or lined:
        failures.append(f"battle royale ranks 2-50: {paid} Mythic Crates, {lined} Mythic lines (must be 0)")

    # Team modes.
    summary = lua.table_from({"botKills": 3, "activeSamples": 30, "samples": 30})
    mythics, bad, mismatch, missing_base = 0, 0, 0, 0
    samples = {}
    for _ in range(N):
        reward, given = W.given(lambda: RS_.AwardTeamResult(player, "win", 1, summary))
        crates = crates_of(given)
        dropped = crates.count("Mythic")
        mythics += dropped
        missing_base += MC_.TeamModeRewards.win.crate not in crates
        rows = [line for line in lines_of(reward) if line.id == "mythic"]
        if len(rows) != 1:
            bad += 1
            continue
        mismatch += (1 if rows[0].crate == "Mythic" else 0) != dropped
        samples.setdefault(rows[0].crate == "Mythic", f"{rows[0].label} | {rows[0].note}")
        if shown(team_chance) not in str(rows[0].label):
            bad += 1
    rate_ok("team win", mythics, team_chance)
    for won, text in sorted(samples.items()):
        report.append(f"    card line when it {'drops' if won else 'misses'}: {text!r}")
        text_ok("team card line", text, team_chance)
    if bad:
        failures.append(f"team win: {bad} cards without one Mythic line carrying {shown(team_chance)}")
    if mismatch:
        failures.append(f"team win: {mismatch} cards disagree with the crates given")
    if missing_base:
        failures.append(f"team win: {missing_base} wins without the win's own crate")

    idle = lua.table_from({"botKills": 3, "activeSamples": 0, "samples": 30, "afk": True})
    for outcome, summ, label in (("loss", summary, "team loss"), ("draw", summary, "team draw"), ("win", idle, "idle team win")):
        paid, lined = 0, 0
        for _ in range(N):
            reward, given = W.given(lambda: RS_.AwardTeamResult(player, outcome, 2, summ))
            paid += crates_of(given).count("Mythic")
            lined += any(line.id == "mythic" for line in lines_of(reward))
        report.append(f"  {label}: {paid} Mythic Crates and {lined} Mythic lines in {N:,}")
        if paid or lined:
            failures.append(f"{label}: {paid} Mythic Crates, {lined} Mythic lines (must be 0)")

    # The lobby tip that says what a win pays: HudClient's block, run as shipped.
    hud = overrides.get(HUD, read(HUD))
    block = re.search(r"^do\n\t-- What a win pays.*?^end$", hud, re.M | re.S)
    if not block:
        failures.append("HudClient: the tip block that reads the win's pay from MatchConfig is gone")
    else:
        tips = lua.execute("local MatchConfig, code = ...\n"
                           "NEW_PLAYER_TIPS = { 1, 2, 3, 4, 5, 6 }\n"
                           "Shared = { WaitForChild = function() return MatchConfig end }\n"
                           "local real = require\nrequire = function(m) return m end\n"
                           "assert(load(code))()\nrequire = real\nreturn NEW_PLAYER_TIPS",
                           MC_, block.group(0))
        tip = tips[6]
        report.append(f"  lobby tip: {tip!r}")
        text_ok("lobby tip", tip, br_chance)
    return failures, report


def plant(path, old, new, base=None):
    source = (base or {}).get(path, read(path))
    assert source.count(old) == 1, (path, old)
    out = dict(base or {})
    out[path] = source.replace(old, new)
    return out


def plants():
    typed_twice = plant(RS, 'label = string.format("Mythic %s chance", odds),', 'label = "Mythic 1% chance",')
    typed_twice = plant(RS, 'or string.format("MYTHIC CRATE %s CHANCE: NOT THIS TIME", odds),',
                        'or "MYTHIC CRATE 1% CHANCE: NOT THIS TIME",', typed_twice)
    typed_twice = plant(RS, 'string.format("+1 MYTHIC CRATE (%s CHANCE)", odds)', '"+1 MYTHIC CRATE (1% CHANCE)"', typed_twice)
    typed_twice = plant(MC, "\tmythicChance = 0.01,\n", "\tmythicChance = 0.02,\n", typed_twice)
    typed_twice = plant(MC, "xp = 900, mythicChance = 0.01 }", "xp = 900, mythicChance = 0.02 }", typed_twice)
    loss_rolls = plant(RS, 'if outcome == "win" and rules.mythicChance then', "if rules.mythicChance then")
    loss_rolls = plant(RS, "\tif summary.afk then\n\t\trecord.streak = 0",
                       "\tsummary.mythic = RewardService.Roll() < rules.mythicChance\n\tif summary.afk then\n\t\trecord.streak = 0",
                       loss_rolls)
    return [
        ("the shown chance differs from the rolled one (roll at 3x the field)",
         plant(RS, "RewardService.Roll() < bracket.mythicChance)", "RewardService.Roll() < bracket.mythicChance * 3)")),
        ("the team roll uses another number than the card shows",
         plant(RS, "summary.mythic = rules.mythicChance ~= nil and RewardService.Roll() < rules.mythicChance",
               "summary.mythic = rules.mythicChance ~= nil and RewardService.Roll() < 0.05")),
        ("the shown chance typed twice (hard-coded 1%, field moved to 2%)", typed_twice),
        ("the game's formatter drops the number", plant(MC, 'return string.format("%g%%", (tonumber(chance) or 0) * 100)', 'return "a small"')),
        ("a rank 2-5 finish rolls too", plant(MC, '{ maxRank = 5,  crate = "Epic",      coins = 1200, xp = 550 }',
                                              '{ maxRank = 5,  crate = "Epic",      coins = 1200, xp = 550, mythicChance = 0.01 }')),
        ("a team loss or draw rolls too", loss_rolls),
        ("the team card says it dropped but no crate is given",
         plant(RS, "\t\tif line.id == \"mythic\" and line.crate then\n\t\t\tCrateService.Give(player, line.crate, 1)",
               "\t\tif false then\n\t\t\tCrateService.Give(player, line.crate, 1)")),
        ("the lobby tip types the chance", plant(HUD, "MatchConfig.ChanceText(win.mythicChance)", '"5%"')),
    ]


def main():
    failures, report = run()
    print(f"mythic_crate_check: {N:,} rolls a case, seed {SEED}, {len(failures)} failed")
    for line in report:
        print(line)
    for f in failures:
        print("  FAIL: " + f)
    ok = not failures
    if "--plant" in sys.argv:
        caught = 0
        planted = plants()
        for label, override in planted:
            found, _ = run(override)
            caught += bool(found)
            print(f"  {'CAUGHT' if found else 'MISSED'}: {label}" + (f" ({found[0]})" if found else ""))
        print(f"mythic_crate_check plant: {caught} of {len(planted)} planted faults caught")
        ok = ok and caught == len(planted)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
