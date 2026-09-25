"""The playtime awards (#76) and the streak table (#77) next to tools/economy_model.py's coins an hour.

Reports, does not judge. Everything about the player is the economy model's own assumption (its three
PROFILES, 2 hours a day every day, a solo player in a server of bots) plus the two below, which are
this file's and nobody has measured:

  - a player MOVES (4+ studs a 30 s check) whenever they are alive in a match, falling in included,
    and STANDS STILL through the lobby gap between matches. That is the worst case for the lobby;
    a player who walks about the lobby is active all the time and always paid.
  - "spectates" = in a server with other people, a player who dies watches to the end of the match
    (roughly the storm's full length; MatchService.concludeIfOver) instead of the match ending at
    their death. Spectating has counted as idle since a2ba3b4.

The time line is sampled every Playtime.SampleSeconds and paid by the rule PlaytimeService applies
(MinActiveSamples of each IntervalSeconds stretch, the ladder from ProgressionData.PlaytimeCoins),
over many simulated 2-hour visits. A reimplementation of the rule, not the Lua: the Lua itself is
checked by tools/playtime_streak_proof.py.

    python tools/playtime_economy_compare.py .
"""

import os
import random
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import economy_model as em  # noqa: E402


def playtime_config(root):
    text = open(os.path.join(root, "ReplicatedStorage", "Shared", "ProgressionData.lua"), encoding="utf-8").read()
    block = text[text.index("ProgressionData.Playtime = {"):]
    block = block[:block.index("\n}") + 2]
    return {k: int(v) for k, v in re.findall(r"(\w+) = (\d+)", block)}


def ladder(cfg, award):
    return min(cfg["CapCoins"], cfg["FirstCoins"] + cfg["StepCoins"] * max(0, award - 1))


def visit_coins(data, profile, n, cfg, spectates, rng, hours=em.HOURS_PER_DAY):
    """Coins one visit of `hours` pays, and how many of its stretches paid."""
    shares = em.placements(profile, n)
    ranks, weights = list(shares), list(shares.values())
    # A time line of (seconds, active) pieces: lobby gap idle, then load + alive active, then spectating idle.
    pieces, total = [], 0.0
    while total < hours * 3600 + 3600:
        rank = rng.choices(ranks, weights)[0]
        whole = em.match_seconds(data, rank, n)
        alive = whole - data.overhead
        pieces += [(data.overhead, False), (alive, True)]
        total += whole
        if spectates:
            longest = em.match_seconds(data, 1, n) - data.overhead
            if longest > alive:
                pieces.append((longest - alive, False))
                total += longest - alive
    # Checks every SampleSeconds, starting at a random phase. A check is active if the player moved
    # since the previous one, i.e. any active time fell in between.
    per = cfg["IntervalSeconds"] // cfg["SampleSeconds"]
    t, i, edge = rng.random() * cfg["SampleSeconds"], 0, pieces[0][0]
    moved, samples, active, awards, coins, stretches, paid = False, 0, 0, 0, 0, 0, 0
    prev_t = 0.0
    while t <= hours * 3600:
        # Walk the pieces between prev_t and t.
        a = prev_t
        while a < t:
            end = min(t, edge)
            if pieces[i][1] and end > a:
                moved = True
            a = end
            if a >= edge:
                i += 1
                edge += pieces[i][0]
        samples += 1
        active += 1 if (moved and samples_total(samples, stretches, per) > 1) else 0
        moved = False
        if samples == per:
            stretches += 1
            if active >= cfg["MinActiveSamples"]:
                awards += 1
                paid += 1
                coins += ladder(cfg, awards)
            samples, active = 0, 0
        prev_t = t
        t += cfg["SampleSeconds"]
    return coins, paid, stretches


def samples_total(samples, stretches, per):
    # The first check of a visit has no earlier position to compare with.
    return stretches * per + samples


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    data = em.Data(root)
    n = data.combatants
    cfg = playtime_config(root)
    rng = random.Random(76)
    visits = 400

    first_hour = sum(ladder(cfg, a) for a in range(1, 3600 // cfg["IntervalSeconds"] + 1))
    later_hour = (3600 // cfg["IntervalSeconds"]) * cfg["CapCoins"]
    print(f"Playtime (ProgressionData.Playtime): {cfg}")
    print(f"  most a visit can pay: hour 1 {first_hour}, each hour after {later_hour}; "
          f"a {em.HOURS_PER_DAY} h visit {first_hour + later_hour * (em.HOURS_PER_DAY - 1)}")
    print(f"  battle royale at {n} combatants; lobby gap {data.overhead} s, load {em.LOAD_SECONDS} s, storm {data.storm_seconds} s")
    print()
    print(f"  {'profile':15} {'cash/h before':>13} {'spectate':>8} {'paid stretches':>14} {'playtime/h':>10} {'+ %':>6}")
    for name, profile in em.PROFILES.items():
        inc = em.Income(data, profile, n)
        for spectates in (False, True):
            coins = paid = stretches = 0
            for _ in range(visits):
                c, p, s = visit_coins(data, profile, n, cfg, spectates, rng)
                coins, paid, stretches = coins + c, paid + p, stretches + s
            per_hour = coins / visits / em.HOURS_PER_DAY
            print(f"  {name:15} {inc.cash:13,.0f} {'yes' if spectates else 'no':>8} {paid / stretches:13.0%} "
                  f"{per_hour:10,.0f} {per_hour / inc.cash:6.1%}")
    print(f"  ({visits} simulated {em.HOURS_PER_DAY} h visits per row; cash/h before is economy_model.py's)")
    print()

    # #77: the seven-day table, over a week of daily claims, beside the model's daily layer.
    text = open(os.path.join(root, "ReplicatedStorage", "Shared", "BattlePassData.lua"), encoding="utf-8").read()
    table = em.lua_table(text, r"^BattlePassData\.DailyRewards = \{", "BattlePassData.lua").array()
    coins = sum(r["amount"] for r in table if r["kind"] == "Coins")
    crates = [r["crate"] for r in table if r["kind"] == "Crate"]
    price = sum(em.crate_coins(data, c) for c in crates)
    sold = sum(em.sell_value(data, c) for c in crates)
    days = len(table)
    print(f"Streak table (BattlePassData.DailyRewards, {days} days): {coins:,} coins + {', '.join(crates)} crates a cycle")
    print(f"  crates at shop price {price:,} coins; sold on opening (1x luck) {sold:,.0f}")
    print(f"  a day: {coins / days:,.0f} coins cash, {(coins + sold) / days:,.0f} with the crates' pulls sold")
    print(f"  an hour of a {em.HOURS_PER_DAY} h day: {coins / days / em.HOURS_PER_DAY:,.0f} cash, "
          f"{(coins + sold) / days / em.HOURS_PER_DAY:,.0f} if sold")
    for name, profile in em.PROFILES.items():
        inc = em.Income(data, profile, n)
        print(f"    {name:15} cash/h {inc.cash:8,.0f} -> +{coins / days / em.HOURS_PER_DAY / inc.cash:5.1%};"
              f"  if sold/h {inc.sold:8,.0f} -> +{(coins + sold) / days / em.HOURS_PER_DAY / inc.sold:5.1%}")


if __name__ == "__main__":
    main()
