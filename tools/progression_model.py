"""Earn-rate model for progression (Rot Rank, Brain Cells, mastery, the Rot Index, the Cell Shop).

    python tools/progression_model.py .

Reads the live numbers from Shared/ProgressionData.lua, MatchConfig.lua, QuestData.lua and CrateData.lua,
so it can't drift from the game, and prints hours to each milestone and what progression adds per hour
next to what placements already pay, for three player profiles. The profiles (matches an hour,
placements, kills) are assumptions, stated below; everything else comes from the sources.

A solo player's match ends when they die (MatchService stops a match with no real player alive), so a
weaker player plays more, shorter matches.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
RARITIES = ["Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret"]


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def need(pattern, text, what, flags=0):
    m = re.search(pattern, text, flags)
    if not m:
        sys.exit(f"progression_model: couldn't read {what}")
    return m


prog = read("ReplicatedStorage/Shared/ProgressionData.lua")
match = read("ReplicatedStorage/Shared/MatchConfig.lua")
quests = read("ReplicatedStorage/Shared/QuestData.lua")
crates = read("ReplicatedStorage/Shared/CrateData.lua")
brainrots = read("ReplicatedStorage/Shared/BrainrotData.lua")

MAX_RANK = int(need(r"ProgressionData\.MaxRank = (\d+)", prog, "MaxRank").group(1))
MAX_PRESTIGE = int(need(r"ProgressionData\.MaxPrestige = (\d+)", prog, "MaxPrestige").group(1))
base, per, cap = map(int, need(r"return math\.min\((\d+) \+ (\d+) \* rank, (\d+)\)", prog, "XpToNext").groups())
OVERFLOW_XP = int(need(r"ProgressionData\.OverflowXp = (\d+)", prog, "OverflowXp").group(1))
OVERFLOW_CELLS = int(need(r"ProgressionData\.OverflowCells = (\d+)", prog, "OverflowCells").group(1))
PRESTIGE_BONUS = float(need(r"ProgressionData\.PrestigeCellBonus = ([\d.]+)", prog, "PrestigeCellBonus").group(1))
cell_base, cell_step, cell_every = map(int, need(r"local cells = (\d+) \+ (\d+) \* \(rank // (\d+)\)", prog, "RankReward").groups())
bonus25 = int(need(r"rank % 25 == 0 then\s+cells \+= (\d+)", prog, "rank 25 bonus").group(1))
bonus10 = int(need(r"rank % 10 == 0 then\s+cells \+= (\d+)", prog, "rank 10 bonus").group(1))
RANK_CRATES = {int(r): c for r, c in re.findall(r'\[(\d+)\] = "(\w+)"', need(r"ProgressionData\.RankCrates = \{([^}]*)\}", prog, "RankCrates").group(1))}
PRESTIGE_REWARD = int(need(r"return \{ cells = (\d+) \* prestige \}", prog, "PrestigeReward").group(1))
TIERS = [(n, int(p), int(c), int(x)) for n, p, c, x in re.findall(r'name = "(\w+)", points = (\d+), cells = (\d+), xp = (\d+)', prog)]
KILL_BOT, KILL_PLAYER = map(int, need(r"KillPoints = \{ bot = (\d+), player = (\d+) \}", prog, "KillPoints").groups())
DISCOVER = {k: int(v) for k, v in re.findall(r"(\w+) = (\d+)", need(r"DiscoverCells = \{([^}]*)\}", prog, "DiscoverCells", re.S).group(1))}
PAGE = {k: int(v) for k, v in re.findall(r"(\w+) = (\d+)", need(r"PageBonus = \{([^}]*)\}", prog, "PageBonus", re.S).group(1))}
SLOTS = re.findall(r'\{ id = "(\w+)", kind = "(\w+)",(?: rarity = "(\w+)",)?(?: xp = \d+,)? price = (\d+), limit = (\d+) \}', prog)

CATALOGUE = {r: len(re.findall(rf'rarity = "{r}", coinValue', brainrots)) for r in RARITIES}


def _count_weapons():
    """WeaponData's own guns plus every pack it merges in (any Shared module it requires whose `.Weapons`
    table it reads). Packs get added over time, so no pack is named here."""
    wd = read("ReplicatedStorage/Shared/WeaponData.lua")
    own = re.search(r"WeaponData\.Weapons = \{\n(.*?)\n\}", wd, re.S)
    total = len(re.findall(r"^\t\w+ = \{", own.group(1), re.M)) if own else 0
    for pack in re.findall(r'local (\w+) = require\(script\.Parent:WaitForChild\("\w+"\)\)', wd):
        name = re.search(rf'local {pack} = require\(script\.Parent:WaitForChild\("(\w+)"\)\)', wd).group(1)
        path = ROOT / "ReplicatedStorage" / "Shared" / f"{name}.lua"
        text = path.read_text(encoding="utf-8") if path.exists() else ""
        block = re.search(r"\.Weapons = \{\n(.*?)\n\}", text, re.S)
        if block and f"{pack}.Weapons" in wd:
            total += len(re.findall(r"^\t\w+ = \{", block.group(1), re.M))
    return total


WEAPONS = _count_weapons()

brackets = [(int(m), c, int(co), int(x)) for m, c, co, x in re.findall(
    r'\{ maxRank = (\d+),\s+crate = "(\w+)",\s+coins = (\d+),\s+xp = (\d+) \}', match)]
XP_BOT_KILL = int(need(r"MatchConfig\.XpPerBotKill = (\d+)", match, "XpPerBotKill").group(1))
COINS_BOT_KILL = int(need(r"MatchConfig\.CoinsPerBotKill = (\d+)", match, "CoinsPerBotKill").group(1))
daily_xp = sum(sorted({int(x) for x in re.findall(r'xp = (\d+) \}', quests.split("QuestData.WeeklyPool")[0])})[-3:])
weekly_xp = sorted(int(x) for x in re.findall(r'xp = (\d+), crate', quests))
weekly_xp = sum(weekly_xp) / len(weekly_xp) * 2 if weekly_xp else 0


def odds(tier):
    body = need(rf"^\t{tier} = \{{\n(.*?)^\t\}},", crates, f"{tier} crate", re.M | re.S).group(1)
    o = {k: float(v) for k, v in re.findall(r"(\w+) = ([\d.]+)", need(r"odds = \{([^}]*)\}", body, f"{tier} odds").group(1))}
    return sum(v for k, v in o.items() if RARITIES.index(k) >= RARITIES.index("Legendary")) / 100


LEG_PLUS = {t: odds(t) for t in ("Common", "Uncommon", "Rare", "Epic", "Legendary")}


def xp_to_next(rank):
    return min(base + per * rank, cap)


def rank_start(rank):
    return sum(xp_to_next(r) for r in range(1, rank))


PRESTIGE_XP = sum(xp_to_next(r) for r in range(1, MAX_RANK))


def rank_for_xp(xp):
    rank, spent = 1, 0
    while rank < MAX_RANK and spent + xp_to_next(rank) <= xp:
        spent += xp_to_next(rank)
        rank += 1
    return rank


def rank_cells(rank, prestige=0):
    cells = cell_base + cell_step * (rank // cell_every)
    cells += bonus25 if rank % 25 == 0 else bonus10 if rank % 10 == 0 else 0
    return int(cells * (1 + PRESTIGE_BONUS * prestige) + 0.5)


CELLS_P0 = sum(rank_cells(r) for r in range(2, MAX_RANK + 1))
RANK_LEG = sum(LEG_PLUS.get(c, 1) for c in RANK_CRATES.values())

# Assumed player profiles: matches an hour, placement shares, bot kills a match.
PROFILES = {
    "casual": dict(mph=13, ranks={25: 0.6, 15: 0.3, 8: 0.1}, kills=1.0),
    "average": dict(mph=11, ranks={15: 0.5, 8: 0.35, 3: 0.15}, kills=2.0),
    "good": dict(mph=9, ranks={1: 0.2, 3: 0.5, 8: 0.3}, kills=5.0),
}
HOURS_PER_DAY = 2


def bracket(rank):
    return next(b for b in brackets if rank <= b[0])


print(f"Rot Rank: {PRESTIGE_XP:,} XP per prestige (rank 2 costs {xp_to_next(1)}, rank 50 {xp_to_next(49)}, rank 100 {xp_to_next(99)})")
print(f"  Brain Cells per prestige: {CELLS_P0:,} at P0, {sum(rank_cells(r, MAX_PRESTIGE) for r in range(2, MAX_RANK + 1)):,} at P{MAX_PRESTIGE}; "
      f"prestige payouts total {sum(PRESTIGE_REWARD * p for p in range(1, MAX_PRESTIGE + 1)):,}")
print(f"  rank crates {RANK_CRATES} -> {RANK_LEG:.2f} expected Legendary+ per prestige")
print(f"Mastery: {len(TIERS)} tiers {[t[1] for t in TIERS]} points; per gun {sum(t[2] for t in TIERS)} Cells, {sum(t[3] for t in TIERS):,} Rank XP"
      + (f"; {WEAPONS} guns -> {WEAPONS * sum(t[2] for t in TIERS):,} Cells lifetime" if WEAPONS else ""))
index_cells = sum(CATALOGUE[r] * DISCOVER.get(r, 0) for r in RARITIES)
print(f"Rot Index: {sum(CATALOGUE.values())} brainrots -> {index_cells:,} Cells for discoveries + {sum(PAGE.values()):,} in page bonuses")
shop_day = sum(int(price) * int(limit) for _, _, _, price, limit in SLOTS)
LISTINGS = [(c, int(v)) for c, v in re.findall(r'\{ id = "(\w+)", cells = (\d+), offer = "\w+" \}', prog)]
if LISTINGS:
    print(f"Cell Shop permanent cosmetics: {', '.join(f'{c} {v:,}' for c, v in LISTINGS)} "
          f"({sum(v for _, v in LISTINGS):,} Cells, about {sum(v for _, v in LISTINGS) / (CELLS_P0 / PRESTIGE_XP * 7166):.0f} h of a good player's rank Cells)")
print(f"Cell Shop: {len(SLOTS)} slots, spending everything costs {shop_day:,} Cells a day; top rarity {max((s[2] for s in SLOTS if s[2]), key=RARITIES.index)}")
print()
print(f"{'profile':8} {'XP/h':>6} {'pass h':>7} {'rank100 h':>9} {'crates/h':>8} {'Leg+/h':>7} {'rank Cells/h':>12} {'rank Leg+ added':>15}")
for name, p in PROFILES.items():
    xp = crates_h = leg = 0.0
    for rank, share in p["ranks"].items():
        _, crate, _, x = bracket(rank)
        xp += share * x
        crates_h += share
        leg += share * LEG_PLUS.get(crate, 0)
    xp_h = (xp + p["kills"] * XP_BOT_KILL) * p["mph"] + (daily_xp + weekly_xp / 7) / HOURS_PER_DAY
    hours = PRESTIGE_XP / xp_h
    leg_h = leg * p["mph"]
    kills_h = p["kills"] * p["mph"]
    print(f"{name:8} {xp_h:6.0f} {49000 / xp_h:7.1f} {hours:9.1f} {crates_h * p['mph']:8.1f} {leg_h:7.2f} {CELLS_P0 / hours:12.0f} {100 * RANK_LEG / hours / max(leg_h, 1e-9):14.1f}%")
    per_gun = kills_h * KILL_BOT / 6
    print(f"{'':8} mastery with 6 guns in rotation: " + ", ".join(f"{t[0]} {t[1] / per_gun:.0f}h" for t in TIERS))
    # The first session is what decides whether the ladder feels alive, so it's worth its own line:
    # a rank in the first few minutes, and the first rank crate inside the first session or two.
    early = ", ".join(f"rank {r} at {60 * rank_start(r) / xp_h:.0f} min" for r in (2, 5, 10, 20))
    print(f"{'':8} early pace: {early} (rank 20 pays the first Rare Crate)")

print()
print("Backfill windfall (paid once when a profile from before progression first loads; Cells only, no crates):")
for pass_xp in (5000, 49000, 100000, 250000):
    rank = rank_for_xp(min(pass_xp, PRESTIGE_XP))
    cells = sum(rank_cells(r) for r in range(2, rank + 1))
    print(f"  {pass_xp:>7,} pass XP -> rank {rank:3d}, {cells:5,} Cells = {cells / shop_day:.1f} days of buying the whole Cell Shop")
common_to_epic = sum(CATALOGUE[r] * DISCOVER[r] for r in RARITIES[:4]) + sum(PAGE[r] for r in RARITIES[:4])
print(f"  plus Index claims: a collector with every Common-Epic brainrot claims {common_to_epic:,} Cells (pages included)")
