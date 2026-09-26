"""The whole economy as one system: coins in, coins out, and what a Robux buys in hours of play.

    python tools/economy_model.py .                   the report, at the battle royale's configured size
    python tools/economy_model.py . --combatants 50   the same for a 50-combatant battle royale
    python tools/economy_model.py . --plant           the planted faults; exits 1 if any fails to fire

Every number the model reasons from is read out of the game's own files (SOURCES below), with the
file and line it came from, so the report stays true when the data moves. What is NOT read is the
player: how often they place, how many they kill, how long they last. Those are PROFILES and the
constants under it, stated as assumptions and printed beside every result.

ECONOMY.md at the repo root is the written report built on this output.
"""
import math
import pathlib
import re
import shutil
import sys
import tempfile

RARITIES = ["Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret"]
SHARED = "ReplicatedStorage/Shared/"
MODULES = "ServerScriptService/Modules/"

# Every file the model reads, and what it takes from each.
SOURCES = {
    SHARED + "MatchConfig.lua": "placement brackets, kill pay, storm schedule, lobby timings, field size",
    SHARED + "MatchEvents.lua": "how often a match is High Stakes, and its placement multiplier",
    SHARED + "CrateData.lua": "crate prices, odds, pity, jackpots, accessory chance, refunds, descriptions",
    SHARED + "BrainrotData.lua": "what every brainrot sells for, and the set-completion bonuses",
    SHARED + "CosmeticData.lua": "cosmetic prices, rarities, and which ones only crates give",
    SHARED + "GamepassConfig.lua": "every Robux price, what each product grants, the pass multipliers",
    SHARED + "QuestData.lua": "daily and weekly quest pay and targets",
    SHARED + "AchievementData.lua": "one-off achievement pay",
    SHARED + "BattlePassData.lua": "Brainrot Pass tier rewards",
    SHARED + "DailySpinData.lua": "Daily Spin segments, weights and the streak multiplier",
    SHARED + "ShopRotation.lua": "how often each crate and each cosmetic is on sale",
    SHARED + "ProgressionData.lua": "rank crates and the Cell Shop (brainrots bought with Brain Cells sell for coins)",
    MODULES + "VendorService.lua": "Rot Vendor prices (the in-match coin sink)",
    MODULES + "LobbyService.lua": "how often a lobby goal pays",
    SHARED + "GameModes.lua": "the team modes' time limits",
    "ServerScriptService/Bootstrap.server.lua": "coins per lobby goal",
    "StarterPlayerScripts/MenuClient.client.lua": "whether the Robux Shop draws crate odds where it sells crates",
}

# --- Assumptions: the player and the clock (not in any file) -------------------------------------
# A profile's non-winning matches land uniformly on the ranks inside `spread`, a slice of the field
# from 0 (the top) to 1 (last). `kills` are bot kills a match: the model is a solo player in a
# server of bots, which is how most matches run while the game is small.
PROFILES = {
    "loses only": dict(win=0.0, spread=(0.4, 1.0), kills=0.5,
                       note="never wins, always in the bottom 60% of the field"),
    "wins sometimes": dict(win=0.04, spread=(0.0, 1.0), kills=2.0,
                           note="wins 1 match in 25, otherwise anywhere in the field"),
    "strong": dict(win=0.20, spread=(0.0, 0.4), kills=5.0,
                   note="wins 1 in 5, otherwise always in the top 40%"),
}
# The team modes, the same three players (s.2b). A solo player on a side of bots, one match's worth
# each, over the mode's full time limit. Team Deathmatch: first to 100 team kills among 15 a side is
# ~6.7 kills a head for the winning side, so a middling player makes ~7, a weak one 2 and a strong
# one 20 (respawns every 5 s). Objective Capture scores the hill, not kills: about 60% of the kills,
# plus captures, seconds stood on an objective the team owns, and kills made defending one.
# `active` is the share of participation checks that count: every respawn costs one check (a fresh
# body is never movement) and a player dies a few times a match. `mvp` is how often they top their team.
# `streak` is multi-kill coins a match (a double is 50).
TEAM_MODES = ("TeamDeathmatch", "KingOfTheHill")
TEAM_QUEST_STATS = ("teamMatches", "teamWins", "assists", "captures", "mvp")
TEAM_PROFILES = {
    "TeamDeathmatch": {
        "loses only": dict(win=0.0, draw=0.0, kills=2, assists=1, revenges=0.3, streak=0, mvp=0.0, active=0.85),
        "wins sometimes": dict(win=0.45, draw=0.1, kills=7, assists=3, revenges=1, streak=25, mvp=0.15, active=0.9),
        "strong": dict(win=0.7, draw=0.05, kills=20, assists=5, revenges=2, streak=200, mvp=0.6, active=0.95),
    },
    "KingOfTheHill": {
        "loses only": dict(win=0.0, draw=0.0, kills=1, assists=1, revenges=0.2, streak=0, mvp=0.0, active=0.85,
                           captures=0.5, hold=30, defends=0.2),
        "wins sometimes": dict(win=0.45, draw=0.1, kills=4, assists=2, revenges=0.6, streak=15, mvp=0.15, active=0.9,
                               captures=2, hold=100, defends=1),
        "strong": dict(win=0.7, draw=0.05, kills=12, assists=4, revenges=1.2, streak=120, mvp=0.6, active=0.95,
                       captures=4, hold=180, defends=3),
    },
}
# A team-mode hour must earn between these multiples of the same player's battle royale hour, coins and
# Pass XP both (Oliver, 2026-09-24: "team gamemodes need better rewards!! make them worth playing"; aimed at
# 1.3-1.5x). Outside it the report says so and the run exits 1.
TEAM_BAND = (1.25, 1.6)
HOURS_PER_DAY = 2          # hours played on a day they play; they play every day
LOAD_SECONDS = 20          # map build plus the canopy descent: not measured, a guess
MIN_ALIVE_SECONDS = 30     # even the first one out lasts this long
ENDGAME_SECONDS = 30       # a winner's last fight, after the final storm phase closes
SPIN_STREAK_DAY = 11       # an everyday player sits at the Daily Spin's streak cap


# --- Reading Lua tables ---------------------------------------------------------------------------
# A reader for the table constructors the data files are written in. Scalars come back as Python
# values; anything else (a Color3, a function call, arithmetic) comes back as Raw text, which no
# number here needs. Each table remembers the line of every key, for citing.

_TOKEN = re.compile(r"""
    (?P<ws>\s+)
  | (?P<lcomment>--\[(?P<ceq>=*)\[.*?\](?P=ceq)\])
  | (?P<comment>--[^\n]*)
  | (?P<lstr>\[(?P<seq>=*)\[.*?\](?P=seq)\])
  | (?P<str>"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*')
  | (?P<num>0x[0-9a-fA-F]+|\d+\.?\d*(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?)
  | (?P<name>[A-Za-z_]\w*)
  | (?P<op>\.\.\.|\.\.|==|~=|<=|>=|//|[-+*/%^\#<>=(){}\[\];:,.])
""", re.S | re.X)


class Raw(str):
    """An expression the reader keeps as text."""


class Table(dict):
    """A Lua table: keyed entries, positional ones under 1..n, and `line[key]` for each."""
    def __init__(self, path):
        super().__init__()
        self.path, self.line = path, {}

    def array(self):
        return [self[i] for i in range(1, len(self) + 1) if i in self]

    def at(self, key):
        return f"{self.path}:{self.line.get(key, '?')}"


def _tokens(text, start):
    pos, line = start, text.count("\n", 0, start) + 1
    while pos < len(text):
        m = _TOKEN.match(text, pos)
        if not m:
            raise ValueError(f"unreadable Lua at line {line}: {text[pos:pos + 30]!r}")
        kind = m.lastgroup
        if kind not in ("ws", "comment", "lcomment"):
            yield kind if kind not in ("ceq", "seq") else "lstr", m.group(0), line
        line += m.group(0).count("\n")
        pos = m.end()


class _Reader:
    """Reads one table constructor, pulling tokens lazily so the rest of the file never has to parse."""

    def __init__(self, text, start, path):
        self.source, self.buffer, self.path = _tokens(text, start), [], path

    def peek(self, ahead=0):
        while len(self.buffer) <= ahead:
            self.buffer.append(next(self.source))
        return self.buffer[ahead]

    def next(self):
        token = self.peek()
        self.buffer.pop(0)
        return token

    def ends_entry(self, ahead):
        return self.peek(ahead)[1] in (",", ";", "}")

    def value(self):
        kind, text, _ = self.peek()
        if text == "{":
            return self.table()
        # A literal is only a literal if the entry ends right after it; `2 * x` stays Raw.
        if kind == "str" and self.ends_entry(1):
            self.next()
            return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), text[1:-1])
        if kind == "num" and self.ends_entry(1):
            self.next()
            return int(text, 0) if not re.search(r"[.eE]", text) or text.startswith("0x") else float(text)
        if text == "-" and self.peek(1)[0] == "num" and self.ends_entry(2):
            self.next()
            number = self.next()[1]
            return -(float(number) if re.search(r"[.eE]", number) else int(number))
        if text in ("true", "false", "nil") and self.ends_entry(1):
            self.next()
            return {"true": True, "false": False, "nil": None}[text]
        return self.raw()

    def raw(self):
        depth, parts = 0, []
        while depth > 0 or not self.ends_entry(0):
            text = self.next()[1]
            depth += text in ("(", "{", "[")
            depth -= text in (")", "}", "]")
            parts.append(text)
        return Raw(" ".join(parts))

    def table(self):
        self.next()  # {
        table, index = Table(self.path), 1
        while True:
            kind, text, line = self.peek()
            if text == "}":
                self.next()
                return table
            if text == "[":
                self.next()
                key = self.value()
                self.next()  # ]
                self.next()  # =
            elif kind == "name" and self.peek(1)[1] == "=":
                key = self.next()[1]
                self.next()  # =
            else:
                key, index = index, index + 1
            table.line[key] = line
            table[key] = self.value()
            if self.peek()[1] in (",", ";"):
                self.next()


def lua_table(text, anchor, path):
    """The table constructor that follows the regex `anchor` in `text`."""
    m = re.search(anchor, text, re.M)
    if not m:
        raise LookupError(f"{path}: no {anchor!r}")
    start = text.index("{", m.end() - 1)
    return _Reader(text, start, path).table()


def lua_number(text, name, path):
    m = re.search(rf"^{re.escape(name)}\s*=\s*([\d.]+)", text, re.M)
    if not m:
        raise LookupError(f"{path}: no {name}")
    return (float(m.group(1)) if "." in m.group(1) else int(m.group(1))), f"{path}:{text.count(chr(10), 0, m.start()) + 1}"


def line_of(text, pattern, path, flags=re.M):
    m = re.search(pattern, text, flags)
    if not m:
        raise LookupError(f"{path}: no {pattern!r}")
    return m, f"{path}:{text.count(chr(10), 0, m.start()) + 1}"


# --- Loading ----------------------------------------------------------------------------------------

class Data:
    """Everything the model reads, with where it read it."""

    def __init__(self, root):
        self.root = pathlib.Path(root)
        self.text, self.missing = {}, []
        for rel in SOURCES:
            path = self.root / rel
            if path.exists():
                self.text[rel] = path.read_text(encoding="utf-8")
            else:
                self.missing.append(rel)
        if self.missing:
            sys.exit("economy_model: missing sources: " + ", ".join(self.missing))
        self._match()
        self._crates()
        self._brainrots()
        self._cosmetics()
        self._robux()
        self._rest()

    def _t(self, rel):
        return self.text[rel], pathlib.Path(rel).name

    def _match(self):
        text, name = self._t(SHARED + "MatchConfig.lua")
        brackets = lua_table(text, r"^MatchConfig\.PlacementBrackets = \{", name)
        self.brackets, self.brackets_at = brackets.array(), brackets.at(1)
        self.bot_kill_coins, _ = lua_number(text, "MatchConfig.CoinsPerBotKill", name)
        self.bot_kill_xp, _ = lua_number(text, "MatchConfig.XpPerBotKill", name)
        self.max_players, _ = lua_number(text, "MatchConfig.MaxPlayers", name)
        self.fill, self.fill_at = lua_number(text, "MatchConfig.BotFillTarget", name)
        # The battle royale's own fill target, if the build carries one (OLIVER_LIST #127).
        try:
            self.fill, self.fill_at = lua_number(text, "MatchConfig.BotFillTargetBattleRoyale", name)
        except LookupError:
            pass
        self.combatants = min(self.fill, self.max_players)
        # The team modes' payout (TeamIncome) and the battle royale's own kill rate it pays kills at.
        self.team = lua_table(text, r"^MatchConfig\.TeamModeRewards = \{", name)
        self.team_at = self.team.at("win")
        self.kill_coins, _ = lua_number(text, "MatchConfig.CoinsPerKill", name)
        self.kill_xp, _ = lua_number(text, "MatchConfig.XpPerKill", name)
        # A team match has no drop selection; everything else between matches is the same.
        self.team_overhead = sum(lua_number(text, f"MatchConfig.{k}", name)[0]
                                 for k in ("ResultsDuration", "Intermission", "AllReadyCountdown"))
        storm = lua_table(text, r"^MatchConfig\.StormPhases = \{", name).array()
        self.storm_seconds = sum(p["holdTime"] + p["shrinkTime"] for p in storm)
        self.overhead = sum(lua_number(text, f"MatchConfig.{k}", name)[0]
                            for k in ("ResultsDuration", "Intermission", "AllReadyCountdown", "DropSelectSeconds"))
        text, name = self._t(SHARED + "MatchEvents.lua")
        none, _ = lua_number(text, "MatchEvents.NoneChance", name)
        events = lua_table(text, r"^MatchEvents\.List = \{", name).array()
        stakes = [e.get("placementMultiplier", 1) for e in events]
        # The average placement multiplier over all matches: plain ones pay 1.
        self.placement_factor = none + (1 - none) * sum(stakes) / len(stakes)

    def _crates(self):
        text, name = self._t(SHARED + "CrateData.lua")
        self.crates = lua_table(text, r"^CrateData\.Crates = \{", name)
        self.crate_order = lua_table(text, r"^CrateData\.Order = \{", name).array()
        text, name = self._t(SHARED + "ShopRotation.lua")
        self.crate_chance = lua_table(text, r"^ShopRotation\.CrateChance = \{", name)
        self.rotation_seconds, _ = lua_number(text, "ShopRotation.RotationSeconds", name)
        self.rarity_weight = lua_table(text, r"^ShopRotation\.RarityWeight = \{", name)
        self.slots = {slot["kind"]: slot["count"] for slot in lua_table(text, r"^ShopRotation\.Slots = \{", name).array()}
        self.slots["Parachute"], _ = lua_number(text, "ShopRotation.ParachuteSlots", name)

    def _brainrots(self):
        text, name = self._t(SHARED + "BrainrotData.lua")
        types = lua_table(text, r"^BrainrotData\.Types = \{", name).array()
        self.brainrots = {r: [t for t in types if t["rarity"] == r] for r in RARITIES}
        self.sell_mean = {r: sum(t["coinValue"] for t in ts) / len(ts) if ts else 0 for r, ts in self.brainrots.items()}
        self.sell_max = {r: max((t["coinValue"] for t in ts), default=0) for r, ts in self.brainrots.items()}
        self.set_bonus = lua_table(text, r"^BrainrotData\.CollectionBonus = \{", name)

    def _cosmetics(self):
        text, name = self._t(SHARED + "CosmeticData.lua")
        items = lua_table(text, r"^CosmeticData\.Items = \{", name)
        self.cosmetics = {k: v for k, v in items.items() if isinstance(v, Table)}
        # CosmeticData.OfKind: what crates can draw. Bundle and rank rewards are never in it.
        self.crate_pool = {k: v for k, v in self.cosmetics.items() if not v.get("bundleOnly") and not v.get("rankOnly")}
        self.shop = {k: v for k, v in self.crate_pool.items() if isinstance(v.get("price"), int) and not v.get("crateOnly")}

    def _robux(self):
        text, name = self._t(SHARED + "GamepassConfig.lua")
        self.passes = lua_table(text, r"^GamepassConfig\.Passes = \{", name)
        self.products = lua_table(text, r"^GamepassConfig\.Products = \{", name)
        self.brainrot_prices = lua_table(text, r"^GamepassConfig\.BrainrotPrices = \{", name)

    def _rest(self):
        text, name = self._t(SHARED + "QuestData.lua")
        self.quests = lua_table(text, r"^QuestData\.Pool = \{", name)
        self.weekly = lua_table(text, r"^QuestData\.WeeklyPool = \{", name).array()
        m, _ = line_of(text, r'^QuestData\.BonusCrate = "(\w+)"', name)
        self.bonus_crate = m.group(1)
        self.weekly_count, _ = lua_number(text, "QuestData.WeeklyCount", name)

        text, name = self._t(SHARED + "AchievementData.lua")
        self.achievements = lua_table(text, r"^AchievementData\.List = \{", name).array()

        text, name = self._t(SHARED + "BattlePassData.lua")
        self.pass_tiers, _ = lua_number(text, "BattlePassData.MaxTier", name)
        self.pass_xp, _ = lua_number(text, "BattlePassData.XpPerTier", name)
        m, _ = line_of(
            text, r"amount = \(premium and (\d+) or (\d+)\) \+ tier \* \(premium and (\d+) or (\d+)\)", name)
        p_base, f_base, p_step, f_step = map(int, m.groups())
        m, _ = line_of(text, r'crate = premium and \(tier >= (\d+) and "(\w+)" or "(\w+)"\) or \(tier >= (\d+) and "(\w+)" or "(\w+)"\)', name)
        p_cut, p_hi, p_lo, f_cut, f_hi, f_lo = m.groups()
        self.pass_reward = {}
        for track, base, step, cut, hi, lo in (("free", f_base, f_step, f_cut, f_hi, f_lo),
                                                ("premium", p_base, p_step, p_cut, p_hi, p_lo)):
            rewards = []
            for tier in range(1, self.pass_tiers + 1):
                if tier % 10 == 0:
                    rewards.append(("crate", hi if tier >= int(cut) else lo))
                elif tier % 5 == 0:
                    rewards.append(("cosmetic", None))
                else:
                    rewards.append(("coins", base + tier * step))
            self.pass_reward[track] = rewards

        text, name = self._t(SHARED + "DailySpinData.lua")
        self.spin = lua_table(text, r"^DailySpinData\.Segments = \{", name).array()
        bonus, _ = lua_number(text, "DailySpinData.StreakBonus", name)
        cap, _ = lua_number(text, "DailySpinData.StreakCap", name)
        self.spin_multiplier = 1 + bonus * min(max(SPIN_STREAK_DAY - 1, 0), cap)

        text, name = self._t(SHARED + "ProgressionData.lua")
        self.cell_shop = lua_table(text, r"^ProgressionData\.ShopSlots = \{", name).array()

        text, name = self._t(MODULES + "VendorService.lua")
        self.vendor = lua_table(text, r"^VendorService\.Products = \{", name).array()

        text, name = self._t(MODULES + "LobbyService.lua")
        self.goal_cooldown, self.goal_cooldown_at = lua_number(text, "local GOAL_PAY_COOLDOWN", name)
        text, name = self._t("ServerScriptService/Bootstrap.server.lua")
        m, self.goal_coins_at = line_of(text, r'AwardBonusCoins\(player, (\d+), "GOAL!"\)', name)
        self.goal_coins = int(m.group(1))

        text, name = self._t(SHARED + "GameModes.lua")
        modes = lua_table(text, r"^GameModes\.Modes = \{", name)
        self.team_modes = {k: modes[k] for k in TEAM_MODES}

        menu = self.text["StarterPlayerScripts/MenuClient.client.lua"]
        self.shop_draws_odds = {}
        for fn in ("renderRobuxShop", "featuredCard"):
            m = re.search(rf"^local function {fn}\(.*?\n(.*?)^end\n", menu, re.S | re.M)
            self.shop_draws_odds[fn] = bool(m) and bool(re.search(r"OddsLine|EffectiveOdds", m.group(1)))


# --- Crate maths ------------------------------------------------------------------------------------

def effective_odds(crate, luck):
    """CrateData.EffectiveOdds, rarity -> percent: best of `luck` rolls, done exactly."""
    odds = crate["odds"]
    total = sum(odds.values())
    out, at_least, above = {}, 0.0, 0.0
    for rarity in reversed(RARITIES):
        weight = odds.get(rarity, 0)
        if weight > 0:
            at_least = min(1.0, at_least + weight / total)
            boosted = 1 - (1 - at_least) ** luck
            out[rarity] = (boosted - above) * 100
            above = boosted
    return out


def long_run(crate, luck=1):
    """Share of opens landing on each rarity once pity is counted. Pity only ever raises its own
    rarity: every cycle of opens ends on exactly one pull at or above it, natural or forced."""
    rates = {r: p / 100 for r, p in effective_odds(crate, luck).items()}
    pity = crate.get("pity")
    if not pity:
        return rates
    floor = RARITIES.index(pity["rarity"])
    p = sum(v for r, v in rates.items() if RARITIES.index(r) >= floor)
    cycle = sum((1 - p) ** k for k in range(pity["every"]))
    forced = (1 - p) ** pity["every"] / cycle
    below = sum(v for r, v in rates.items() if RARITIES.index(r) < floor)
    if below <= 0:
        return rates
    out = {}
    for r, v in rates.items():
        out[r] = v * (1 - forced / below) if RARITIES.index(r) < floor else v
    out[pity["rarity"]] = out.get(pity["rarity"], 0) + forced
    return out


def accessory_rate(data, crate, luck=1, owned=()):
    """How often a brainrot crate really pays an accessory: it only swaps the brainrot out when
    there is an unowned accessory at the rarity rolled (CrateService.Open), pity included."""
    chance = crate.get("accessoryChance", 0) / 100
    return sum(p * chance for r, p in long_run(crate, luck).items() if accessories_at(data, r, owned))


def accessories_at(data, rarity, owned=()):
    return [k for k, v in data.crate_pool.items() if v["kind"] == "Accessory" and v["rarity"] == rarity and k not in owned]


def sell_value(data, tier, luck=1):
    """Coins one crate is worth if what comes out is sold (jackpot included; accessories sell for
    nothing). A fresh profile, so an accessory can replace the brainrot at every rarity that has one."""
    crate = data.crates[tier]
    if crate.get("category", "Brainrot") != "Brainrot":
        return 0.0
    chance = crate.get("accessoryChance", 0) / 100
    value = 0.0
    for r, p in long_run(crate, luck).items():
        keep = 1 - (chance if accessories_at(data, r) else 0)
        value += p * keep * data.sell_mean[r]
    return value + jackpot_value(crate)


def jackpot_value(crate):
    jackpot = crate.get("jackpot")
    return jackpot["chance"] * (jackpot["min"] + jackpot["max"]) / 2 if jackpot else 0.0


# --- 1. Odds a player reads against odds the code rolls --------------------------------------------

_WORDS = {"a third": 1 / 3, "a quarter": 1 / 4, "half": 1 / 2}
_RARITY = "(" + "|".join(RARITIES) + ")"


def claims(text):
    """(stated fraction, rarity, phrase) for every chance a sentence states about a rarity."""
    found = []
    for m in re.finditer(rf"(\d+(?:\.\d+)?)% (?:shot at |chance of )?(?:a |an )?{_RARITY}", text):
        found.append((float(m.group(1)) / 100, m.group(2), m.group(0)))
    for m in re.finditer(rf"{_RARITY} about one time in (\w+)", text):
        n = {"two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "ten": 10}.get(m.group(2))
        if n:
            found.append((1 / n, m.group(1), m.group(0)))
    for word, share in _WORDS.items():
        for m in re.finditer(rf"\b{word} {_RARITY}", text):
            found.append((share, m.group(1), m.group(0)))
    return found


def odds_audit(data):
    """Everything a player reads about a crate's odds that the roll does not do. Lucks checked:
    every luck a player can open a paid crate at (1, and the 2x Crate Luck pass, which the Daily
    Spin also hands out for a day). Beginner's Luck is left out: its cards print no percentages."""
    pass_luck = data.passes["CrateLuck"].get("luck", 2)
    lucks = sorted({1, pass_luck})
    findings = []
    texts = []
    for tier, crate in data.crates.items():
        if isinstance(crate, Table) and crate.get("description"):
            texts.append((f"{tier} Crate card", crate.at("description"), crate["description"], crate))
    for key, product in data.products.items():
        if isinstance(product, Table) and product.get("grant", {}).get("kind") == "Crate":
            crate = data.crates.get(product["grant"]["crate"])
            texts.append((f"{product['name']} (Robux Shop, {product['suggestedPrice']} R$)", product.at("description"),
                           product["description"], crate))
            if product.get("worth"):
                texts.append((f"{product['name']} featured card", product.at("worth"), product["worth"], crate))
    for label, where, text, crate in texts:
        for share, rarity, phrase in claims(text):
            for luck in lucks:
                odds = effective_odds(crate, luck)
                exact = odds.get(rarity, 0) / 100
                better = sum(v for r, v in odds.items() if RARITIES.index(r) >= RARITIES.index(rarity)) / 100
                # Either reading of the phrase will do ("12% Legendary" or "12% Legendary or better"),
                # to the nearest whole percent: a claim only fails if it is wrong on both.
                if min(abs(share - exact), abs(share - better)) > 0.0051 + 0.02 * share:
                    findings.append(dict(kind="text", label=label, where=where, phrase=phrase, luck=luck,
                                         says=share * 100, rolls=exact * 100, better=better * 100))
        jackpot = crate.get("jackpot") if crate else None
        for m in re.finditer(r"(\d+)% (?:chance of a |coin )?(?:(\d+)K-(\d+)K )?(?:coin )?jackpot", text):
            says = int(m.group(1)) / 100
            if not jackpot or abs(says - jackpot["chance"]) > 0.005 or (
                    m.group(2) and (int(m.group(2)) * 1000, int(m.group(3)) * 1000) != (jackpot["min"], jackpot["max"])):
                findings.append(dict(kind="jackpot", label=label, where=where, phrase=m.group(0), luck=1,
                                     says=says * 100, rolls=(jackpot or {}).get("chance", 0) * 100, better=None))
    for tier, crate in data.crates.items():
        if isinstance(crate, Table) and crate.get("accessoryChance"):
            for luck in lucks:
                real = accessory_rate(data, crate, luck) * 100
                if abs(real - crate["accessoryChance"]) > 0.05:
                    findings.append(dict(kind="accessory", label=f"{tier} Crate card", where=crate.at("accessoryChance"),
                                         phrase=f"+ {crate['accessoryChance']}% accessory", luck=luck,
                                         says=crate["accessoryChance"], rolls=real, better=None))
    return findings


def robux_crates_without_odds(data):
    """Crates sold for Robux on a screen that draws no odds (MenuClient's Robux Shop)."""
    sold = []
    for key, product in data.products.items():
        if isinstance(product, Table) and product.get("grant", {}).get("kind") in ("Crate", "Bundle"):
            grant = product["grant"]
            crates = [grant["crate"]] if grant["kind"] == "Crate" else \
                [c["crate"] for c in grant["contents"].array() if c.get("kind") == "Crate"]
            if crates:
                screen = "featuredCard" if product.get("featured") else "renderRobuxShop"
                if not data.shop_draws_odds[screen]:
                    sold.append((product["name"], product["suggestedPrice"], screen, product.at("grant")))
    return sold


# --- 2. Income --------------------------------------------------------------------------------------

def bracket_for(data, rank):
    return next((b for b in data.brackets if rank <= b["maxRank"]), None)


def placements(profile, n):
    """rank -> share of matches."""
    shares = {1: profile["win"]} if profile["win"] else {}
    lo, hi = profile["spread"]
    first = max(2, math.floor(lo * n) + 1)
    last = max(first, min(n, math.ceil(hi * n)))
    rest = (1 - profile["win"]) / (last - first + 1)
    for rank in range(first, last + 1):
        shares[rank] = shares.get(rank, 0) + rest
    return shares


def match_seconds(data, rank, n):
    alive = data.storm_seconds * (n - rank) / max(n - 1, 1)
    alive = max(MIN_ALIVE_SECONDS, alive) + (ENDGAME_SECONDS if rank == 1 else 0)
    return data.overhead + LOAD_SECONDS + alive


class Income:
    """One profile's steady state: per match, per hour, per day."""

    def __init__(self, data, profile, n, luck=1):
        self.data, self.profile, self.n = data, profile, n
        shares = placements(profile, n)
        seconds = sum(s * match_seconds(data, r, n) for r, s in shares.items())
        self.mph = 3600 / seconds
        self.minutes = seconds / 60
        cash = xp = top10 = 0.0
        crates = {}
        for rank, share in shares.items():
            b = bracket_for(data, rank)
            if not b:
                continue
            cash += share * math.floor(b["coins"] * data.placement_factor)
            xp += share * b["xp"]
            crates[b["crate"]] = crates.get(b["crate"], 0) + share
            # A win's second roll for a Mythic Crate (the bracket's `mythicChance`), on top of its crate.
            crates["Mythic"] = crates.get("Mythic", 0) + share * b.get("mythicChance", 0)
            top10 += share if rank <= 10 else 0
        kills = profile["kills"]
        self.match_cash = cash + kills * data.bot_kill_coins
        self.match_xp = xp + kills * data.bot_kill_xp
        self.jackpot_per_match = sum(s * jackpot_value(data.crates[c]) for c, s in crates.items())
        self.sell_per_match = sum(s * (sell_value(data, c, luck) - jackpot_value(data.crates[c])) for c, s in crates.items())
        self.per_hour = dict(kills=kills * self.mph, matches=self.mph, wins=profile["win"] * self.mph,
                             top10=top10 * self.mph, crates=sum(crates.values()) * self.mph,
                             # The team-mode quests: a battle royale player never finishes them.
                             **{stat: 0 for stat in TEAM_QUEST_STATS})
        self._daily(luck)
        self.xp_per_hour = self.match_xp * self.mph + self.quest_xp / HOURS_PER_DAY

    def _done(self, quest, hours):
        """1 if the quest gets done in `hours`. Stats the model has no rate for (chests, damage,
        goals and the like) are assumed done."""
        rate = self.per_hour.get(quest["stat"])
        return 1.0 if rate is None else float(rate * hours >= quest["target"])

    def _daily(self, luck):
        d, h = self.data, HOURS_PER_DAY
        self.quest_cash, self.quest_xp, done_all = 0.0, 0.0, 1.0
        for tier in ("easy", "medium", "hard"):
            pool = d.quests[tier].array()
            done = [self._done(q, h) for q in pool]
            self.quest_cash += sum(dn * q["coins"] for dn, q in zip(done, pool)) / len(pool)
            self.quest_xp += sum(dn * q["xp"] for dn, q in zip(done, pool)) / len(pool)
            done_all *= sum(done) / len(pool)
        self.bonus_crates = done_all
        weekly = [(self._done(q, h * 7), q) for q in d.weekly]
        per_week = d.weekly_count / len(weekly)
        self.weekly_cash = sum(dn * q["coins"] for dn, q in weekly) * per_week
        self.weekly_sell = sum(dn * sell_value(d, q["crate"], luck) for dn, q in weekly) * per_week
        spin_total = sum(s["weight"] for s in d.spin)
        self.spin_cash = self.spin_sell = 0.0
        for s in d.spin:
            w = s["weight"] / spin_total
            if s["kind"] == "Coins":
                self.spin_cash += w * math.floor(s["amount"] * d.spin_multiplier)
            elif s["kind"] == "Crate":
                self.spin_sell += w * sell_value(d, s["crate"], luck)
            elif s["kind"] == "Brainrot":
                total = sum(s["rarities"].values())
                self.spin_sell += w * sum(p / total * d.sell_mean[r] for r, p in s["rarities"].items())
        self.day_cash = self.quest_cash + self.spin_cash + self.weekly_cash / 7
        self.day_sell = self.bonus_crates * sell_value(d, d.bonus_crate, luck) + self.spin_sell + self.weekly_sell / 7

    # Coins an hour: earned and jackpots (`cash`), and with every brainrot pulled sold (`sold`).
    @property
    def cash(self):
        return (self.match_cash + self.jackpot_per_match) * self.mph + self.day_cash / HOURS_PER_DAY

    @property
    def sold(self):
        return self.cash + self.sell_per_match * self.mph + self.day_sell / HOURS_PER_DAY

    @property
    def earned(self):
        """The coins 2x SahurCoins doubles: everything but jackpots and sales."""
        return self.match_cash * self.mph + (self.quest_cash + self.spin_cash + self.weekly_cash / 7) / HOURS_PER_DAY


class TeamIncome(Income):
    """The same steady state for a team mode, from MatchConfig.TeamModeRewards, line for line as
    RewardService.TeamBreakdown pays it (tools/team_rewards_check.py runs the real one)."""

    def __init__(self, data, mode, profile, luck=1):
        self.data, self.profile, self.mode = data, profile, mode
        t = data.team
        limit = data.team_modes[mode]["timeLimit"]
        seconds = limit + data.team_overhead + LOAD_SECONDS
        self.mph, self.minutes = 3600 / seconds, seconds / 60
        shares = {"win": profile["win"], "draw": profile["draw"], "loss": 1 - profile["win"] - profile["draw"]}
        cash = xp = 0.0
        crates = {}
        for outcome, share in shares.items():
            r = t[outcome]
            cash += share * r["coins"]
            xp += share * r["xp"]
            if r.get("crate"):
                crates[r["crate"]] = crates.get(r["crate"], 0) + share
        # A win's Mythic Crate roll (TeamModeRewards.mythicChance), as the battle royale's rank 1.
        crates["Mythic"] = crates.get("Mythic", 0) + shares["win"] * t.get("mythicChance", 0)
        self.lines = {"result": (cash, xp)}

        def line(name, coins, x):
            self.lines[name] = (coins, x)

        kills = min(profile["kills"], t["kill"]["cap"])  # bot kills: a solo player among bots
        line("kills", kills * data.bot_kill_coins, kills * data.bot_kill_xp)
        for key, rule in (("assists", "assist"), ("revenges", "revenge"), ("captures", "capture"), ("defends", "defend")):
            n = min(profile.get(key, 0), t[rule]["cap"])
            line(key, n * t[rule]["coins"], n * t[rule]["xp"])
        line("streaks", min(profile["streak"], t["streak"]["cap"]), 0)
        hold = min(profile.get("hold", 0), t["hold"]["capSeconds"])
        line("hold", hold * t["hold"]["coinsPerSecond"], hold * t["hold"]["xpPerSecond"])
        line("mvp", profile["mvp"] * t["mvp"]["coins"], profile["mvp"] * t["mvp"]["xp"])
        # TEAM BONUS. The first win of the day, spread over the day's matches: the chance a day of
        # HOURS_PER_DAY holds at least one win, over the matches in it. Its Epic Crate counts when sold.
        b = t["bonus"]
        w = profile["win"]
        per_day = self.mph * HOURS_PER_DAY
        first = (1 - (1 - w) ** per_day) / per_day
        line("firstWin", first * b["firstWin"]["coins"], first * b["firstWin"]["xp"])
        crates[b["firstWin"]["crate"]] = crates.get(b["firstWin"]["crate"], 0) + first
        # The win streak, wins independent: a win after k straight wins pays min(k, maxSteps) steps, and
        # P(at least k straight wins before this one) is w^k.
        steps = w * sum(w ** k for k in range(1, b["winStreak"]["maxSteps"] + 1))
        line("winStreak", steps * b["winStreak"]["coins"], steps * b["winStreak"]["xp"])
        p = t["participation"]
        samples = math.floor(limit / p["sampleSeconds"] * profile["active"])
        minutes = samples * p["sampleSeconds"] / 60
        line("time", minutes * p["coinsPerMinute"], minutes * p["xpPerMinute"])

        self.match_cash = sum(c for c, _ in self.lines.values())
        self.match_xp = sum(x for _, x in self.lines.values())
        self.jackpot_per_match = sum(s * jackpot_value(data.crates[c]) for c, s in crates.items())
        self.sell_per_match = sum(s * (sell_value(data, c, luck) - jackpot_value(data.crates[c])) for c, s in crates.items())
        # The kills quest counts every kill up to maxPaidKills (MatchService's live path).
        self.per_hour = dict(kills=min(profile["kills"], t["maxPaidKills"]) * self.mph, matches=self.mph, wins=0, top10=0,
                             crates=sum(crates.values()) * self.mph, teamMatches=self.mph,
                             teamWins=profile["win"] * self.mph, assists=profile["assists"] * self.mph,
                             captures=profile.get("captures", 0) * self.mph, mvp=profile["mvp"] * self.mph)
        self._daily(luck)
        self.xp_per_hour = self.match_xp * self.mph + self.quest_xp / HOURS_PER_DAY


def team_comparison(data, incomes):
    """Every team mode and profile against the same profile's battle royale hour: (mode, profile,
    team income, coins ratio, XP ratio, in band)."""
    rows = []
    for mode in TEAM_MODES:
        for name, profile in TEAM_PROFILES[mode].items():
            team, br = TeamIncome(data, mode, profile), incomes[name]
            coins = (team.match_cash + team.jackpot_per_match) * team.mph / ((br.match_cash + br.jackpot_per_match) * br.mph)
            xp = team.match_xp * team.mph / (br.match_xp * br.mph)
            ok = TEAM_BAND[0] <= coins <= TEAM_BAND[1] and TEAM_BAND[0] <= xp <= TEAM_BAND[1]
            rows.append((mode, name, team, coins, xp, ok))
    return rows


def one_offs(data, income, hours):
    """Coins paid once by the time `hours` have been played: the free pass track, and the
    achievements the model has a rate for (kills, wins, matches, top 10s, crates earned)."""
    xp = hours * income.xp_per_hour
    tiers = min(data.pass_tiers, int(xp // data.pass_xp) + 1)
    coins = sum(v for k, v in data.pass_reward["free"][:tiers] if k == "coins")
    counts = {k: v * hours for k, v in income.per_hour.items()}
    for a in data.achievements:
        if a["stat"] in counts and counts[a["stat"]] >= a["target"]:
            coins += a["coins"]
    return coins


def hours_to(data, income, price, sold=False, cap=100000):
    """Hours of play until `price` coins have come in (steady state plus one-offs), or None."""
    rate = income.sold if sold else income.cash
    if rate <= 0:
        return None
    lo, hi = 0.0, price / rate
    while hi < cap and hi * rate + one_offs(data, income, hi) < price:
        hi *= 2
    if hi >= cap:
        return None
    for _ in range(60):
        mid = (lo + hi) / 2
        if mid * rate + one_offs(data, income, mid) >= price:
            hi = mid
        else:
            lo = mid
    return hi


# --- 3. Wanting a crate exclusive -----------------------------------------------------------------

def cheapest_route(data, item_id):
    """The coin crate that gets one particular crate-drawn cosmetic for the fewest coins on average,
    for a profile that owns none of that rarity yet: (crate tier, opens, coins net of what sells)."""
    item = data.crate_pool[item_id]
    best = None
    for tier, crate in data.crates.items():
        if not isinstance(crate, Table) or not crate.get("coinPrice"):
            continue
        kinds = crate.get("kinds").array() if crate.get("kinds") else [crate.get("category")]
        rate = long_run(crate).get(item["rarity"], 0)
        if crate.get("category", "Brainrot") == "Brainrot":
            if item["kind"] != "Accessory":
                continue
            kinds, rate = ["Accessory"], rate * crate.get("accessoryChance", 0) / 100
        elif item["kind"] not in kinds:
            continue
        pool = [k for k, v in data.crate_pool.items() if v["kind"] in kinds and v["rarity"] == item["rarity"]]
        if rate <= 0 or item_id not in pool:
            continue
        # Drawn without repeats, so the one wanted is equally likely to be any of the pool's draws.
        opens = (len(pool) + 1) / 2 / rate
        coins = opens * (crate["coinPrice"] - sell_value(data, tier))
        if not best or coins < best[2]:
            best = (tier, opens, coins)
    return best


def set_route(data, rarity):
    """The coin crate that completes a rarity's brainrot set for the fewest coins on average, net of
    selling what else comes out: (crate tier, opens, net coins). Collecting m brainrots drawn evenly
    takes m * (1 + 1/2 + ... + 1/m) pulls of that rarity."""
    m = len(data.brainrots[rarity])
    pulls = m * sum(1 / k for k in range(1, m + 1))
    best = None
    for tier, crate in data.crates.items():
        if not isinstance(crate, Table) or not crate.get("coinPrice") or crate.get("category", "Brainrot") != "Brainrot":
            continue
        swap = crate.get("accessoryChance", 0) / 100 if accessories_at(data, rarity) else 0
        rate = long_run(crate).get(rarity, 0) * (1 - swap)
        if rate <= 0:
            continue
        opens = pulls / rate
        coins = opens * (crate["coinPrice"] - sell_value(data, tier))
        if not best or coins < best[2]:
            best = (tier, opens, coins)
    return best


def on_sale(data, kind):
    """id -> chance a shop cosmetic of `kind` is on sale in a given rotation. ShopRotation draws
    `count` of them by rarity weight without repeats; every order of draws is walked, exactly."""
    pool = [(k, data.rarity_weight[v["rarity"]]) for k, v in data.shop.items() if v["kind"] == kind]
    chance = {k: 0.0 for k, _ in pool}

    def walk(left, draws, p, taken):
        if draws == 0 or not left:
            for k in taken:
                chance[k] += p
            return
        total = sum(w for _, w in left)
        for i, (k, w) in enumerate(left):
            walk(left[:i] + left[i + 1:], draws - 1, p * w / total, taken + [k])
    walk(pool, data.slots.get(kind, 0), 1.0, [])
    return chance


def wait_minutes(data, chance):
    """Average minutes of waiting for something with this chance per rotation to be on sale, or None
    if it never is."""
    return (1 / chance - 1) * data.rotation_seconds / 60 if chance > 0 else None


# --- 4. Robux ---------------------------------------------------------------------------------------

def pack_rate(data):
    """Coins per Robux at the best coin pack: the game's own exchange rate."""
    best = None
    for key, product in data.products.items():
        if isinstance(product, Table) and product.get("grant", {}).get("kind") == "Coins":
            rate = product["grant"]["amount"] / product["suggestedPrice"]
            if not best or rate > best[0]:
                best = (rate, product.at("suggestedPrice"))
    return best


def crate_coins(data, tier):
    """A crate in coins: its coin price, or for a Robux-only crate what its pulls sell for."""
    crate = data.crates[tier]
    return crate["coinPrice"] if crate.get("coinPrice") else sell_value(data, tier)


def product_for(data, kind, field, value):
    for product in data.products.values():
        if isinstance(product, Table) and product["grant"].get("kind") == kind and product["grant"].get(field) == value:
            return product
    return None


def robux_sections(data, incomes):
    rate, rate_at = pack_rate(data)
    goods, bundles, brainrots, passes = [], [], [], []
    for key, product in sorted(data.products.items(), key=lambda kv: kv[1]["suggestedPrice"] if isinstance(kv[1], Table) else 0):
        if not isinstance(product, Table):
            continue
        grant, price = product["grant"], product["suggestedPrice"]
        if grant["kind"] == "Coins":
            goods.append((product["name"], price, grant["amount"], product.at("suggestedPrice")))
        elif grant["kind"] == "Crate":
            goods.append((product["name"], price, crate_coins(data, grant["crate"]), product.at("suggestedPrice")))
        elif grant["kind"] == "Bundle":
            coins, robux, unpriced = 0.0, 0.0, []
            for entry in grant["contents"].array():
                amount = entry.get("amount", 1)
                if entry["kind"] == "Coins":
                    coins += entry["amount"]
                    robux += entry["amount"] / rate
                elif entry["kind"] == "Crate":
                    coins += crate_coins(data, entry["crate"]) * amount
                    sold_as = product_for(data, "Crate", "crate", entry["crate"])
                    robux += sold_as["suggestedPrice"] * amount if sold_as else 0
                elif entry["kind"] == "Consumable":
                    sold_as = product_for(data, "Consumable", "consumable", entry["consumable"])
                    if sold_as:
                        robux += sold_as["suggestedPrice"] * amount
                    else:
                        unpriced.append(f"{amount} {entry['consumable']}")
                else:
                    unpriced.append(str(entry.get("id")))
            claim = re.search(r"Worth ([\d,]+)\+? R\$", product.get("worth") or "")
            bundles.append(dict(name=product["name"], price=price, coins=coins, robux=robux, unpriced=unpriced,
                                claim=int(claim.group(1).replace(",", "")) if claim else None,
                                where=product.at("worth")))
    for rarity in RARITIES:
        price = data.brainrot_prices.get(rarity)
        count = len(data.brainrots[rarity])
        if price and count:
            brainrots.append(dict(rarity=rarity, price=price, mean=data.sell_mean[rarity], max=data.sell_max[rarity],
                                  count=count, set_robux=price * count, set_bonus=data.set_bonus.get(rarity, 0),
                                  set_sell=sum(t["coinValue"] for t in data.brainrots[rarity]),
                                  where=data.brainrot_prices.at(rarity)))
    boost = data.passes["CoinBoost"]
    mult = boost.get("multiplier", 2)
    passes.append((boost["name"], boost["suggestedPrice"], "coins earned",
                   {k: inc.earned * (mult - 1) for k, inc in incomes.items()}, data.passes.at("CoinBoost")))
    luck = data.passes["CrateLuck"]
    passes.append((luck["name"], luck["suggestedPrice"], "coins if every pull is sold",
                   {k: Income(data, inc.profile, inc.n, luck=luck.get("luck", 2)).sold - inc.sold for k, inc in incomes.items()},
                   data.passes.at("CrateLuck")))
    return rate, rate_at, goods, bundles, brainrots, passes


def premium_pass(data, incomes):
    """The premium track in coins (crates at their coin price; cosmetics uncounted), and the hours
    it takes each profile to reach its last tier."""
    worth = sum(v if k == "coins" else crate_coins(data, v) if k == "crate" else 0 for k, v in data.pass_reward["premium"])
    xp = (data.pass_tiers - 1) * data.pass_xp
    reach = {k: xp / inc.xp_per_hour for k, inc in incomes.items()}
    return worth, reach


# --- Report -----------------------------------------------------------------------------------------

def fmt(n):
    return f"{n:,.0f}"


def hours(h):
    if h is None:
        return "never"
    return f"{h * 60:.0f} min" if h < 1 else f"{h:,.1f} h" if h < 100 else f"{h:,.0f} h"


def report(data, n):
    print(f"Brain Rot Royale economy model: a {n}-combatant battle royale, solo player among bots")
    print(f"Reads {len(SOURCES)} sources ({len(data.missing)} missing). Field size from {data.fill_at}"
          + (f", overridden to {n} on the command line" if n != data.combatants else ""))
    print(f"Assumed: {HOURS_PER_DAY} h a day, every day; {LOAD_SECONDS} s to load and land; "
          f"lobby {data.overhead} s between matches (MatchConfig); a storm of {data.storm_seconds} s.")
    print()

    print("1. ODDS A PLAYER READS AGAINST ODDS THE CODE ROLLS")
    sold = robux_crates_without_odds(data)
    print(f"  Robux Shop screens that draw crate odds: " + ", ".join(
        f"{k} {'yes' if v else 'NO'}" for k, v in data.shop_draws_odds.items()))
    for name, price, screen, where in sold:
        print(f"    sells {name} for {price} R$ on {screen} with no odds shown ({where})")
    findings = odds_audit(data)
    for f in findings:
        if f["kind"] == "text":
            print(f"  {f['label']}: \"{f['phrase']}\" but at {f['luck']}x luck it rolls {f['rolls']:.2f}% "
                  f"({f['better']:.2f}% counting rarer). {f['where']}")
        elif f["kind"] == "accessory":
            print(f"  {f['label']}: \"{f['phrase']}\" but a new player gets one {f['rolls']:.2f}% of the time at "
                  f"{f['luck']}x luck, and it replaces the brainrot. {f['where']}")
        else:
            print(f"  {f['label']}: \"{f['phrase']}\" but the jackpot fires {f['rolls']:.0f}%. {f['where']}")
    texts = sum(1 for c in data.crates.values() if isinstance(c, Table) and c.get("description")) + sum(
        1 for p in data.products.values() if isinstance(p, Table) and p.get("grant", {}).get("kind") == "Crate")
    print(f"  ({texts} crate texts read, {len(findings)} findings, {len(sold)} Robux listings without odds)")
    print()

    incomes = {name: Income(data, p, n) for name, p in PROFILES.items()}
    print("2. COINS AN HOUR")
    print(f"  {'profile':15} {'matches/h':>9} {'min/match':>9} {'match coins/h':>13} {'daily extras/h':>14} "
          f"{'cash/h':>8} {'if sold/h':>9}")
    for name, inc in incomes.items():
        print(f"  {name:15} {inc.mph:9.1f} {inc.minutes:9.1f} {fmt((inc.match_cash + inc.jackpot_per_match) * inc.mph):>13} "
              f"{fmt(inc.day_cash / HOURS_PER_DAY):>14} {fmt(inc.cash):>8} {fmt(inc.sold):>9}")
    for name, p in PROFILES.items():
        print(f"    {name}: {p['note']}, {p['kills']} bot kills a match")
    print(f"  cash = placement + kill coins + crate jackpots + quests, spin and weeklies spread over the day;")
    print(f"  if sold = the same plus every brainrot pulled from those crates sold at its coinValue.")
    print(f"  Placement pays: " + ", ".join(f"≤{b['maxRank']} {b['coins']}" for b in data.brackets)
          + f" ({data.brackets_at}); ranks past {n} are never reached.")
    goal_hour = 3600 / data.goal_cooldown * data.goal_coins
    print(f"  Lobby football, never readying: up to {fmt(goal_hour)} coins/h ({data.goal_coins} a goal "
          f"{data.goal_coins_at}, one per {data.goal_cooldown} s {data.goal_cooldown_at}).")
    print(f"  The battle royale's match coins a minute of play, which the team modes are held to (s.2b): "
          + ", ".join(f"{k} {(inc.match_cash + inc.jackpot_per_match) * inc.mph / 60:.0f}" for k, inc in incomes.items()) + ".")
    print()
    print(f"2b. TEAM MODES AGAINST THE BATTLE ROYALE (MatchConfig.TeamModeRewards, {data.team_at}; band {TEAM_BAND[0]}-{TEAM_BAND[1]}x)")
    print(f"  {'mode':15} {'profile':15} {'match/h':>7} {'coins/h':>8} {'BR':>8} {'ratio':>6} {'XP/h':>7} {'BR':>7} {'ratio':>6}"
          f" {'cash/h':>8} {'if sold/h':>9}")
    rows = team_comparison(data, incomes)
    for mode, name, team, coins, xp, ok in rows:
        br = incomes[name]
        print(f"  {mode:15} {name:15} {team.mph:7.2f} {fmt((team.match_cash + team.jackpot_per_match) * team.mph):>8} "
              f"{fmt((br.match_cash + br.jackpot_per_match) * br.mph):>8} {coins:6.2f} {fmt(team.match_xp * team.mph):>7} "
              f"{fmt(br.match_xp * br.mph):>7} {xp:6.2f} {fmt(team.cash):>8} {fmt(team.sold):>9}"
              + ("" if ok else "   <- OUT OF BAND"))
    for mode in TEAM_MODES:
        mid = next(r[2] for r in rows if r[0] == mode and r[1] == "wins sometimes")
        print(f"    {mode}, wins sometimes, one match: " + ", ".join(
            f"{k} {c:.0f}c/{x:.0f}xp" for k, (c, x) in mid.lines.items() if c or x))
    print(f"  {sum(1 for r in rows if r[5])} of {len(rows)} in band. coins/h and XP/h are match pay only (the daily extras"
          f" are the same whichever mode); cash/h and if sold/h add them, as in s.2.")
    cells = sum(slot["price"] * slot["limit"] for slot in data.cell_shop if slot["kind"] == "Brainrot")
    coins = sum(data.sell_mean[slot["rarity"]] * slot["limit"] for slot in data.cell_shop if slot["kind"] == "Brainrot")
    print(f"  The Cell Shop's brainrots, bought every day and sold: {fmt(cells)} Brain Cells -> {fmt(coins)} coins "
          f"({coins / cells:.1f} coins a Cell; ProgressionData.ShopSlots).")
    print()

    print("3. HOURS UNTIL A PLAYER CAN AFFORD IT (cash / selling every pull)")
    targets = []
    for tier in ("Common", "Rare", "Epic", "Legendary", "Mythic", "Style", "DeluxeStyle", "PrestigeStyle"):
        crate = data.crates.get(tier)
        if crate and crate.get("coinPrice"):
            targets.append((f"{crate['name']} ({fmt(crate['coinPrice'])}, on the shelf "
                            f"{data.crate_chance.get(tier, 1) * 100:.0f}% of rotations)", crate["coinPrice"]))
    prices = sorted(v["price"] for v in data.shop.values())
    targets.append((f"cheapest shop cosmetic ({fmt(prices[0])})", prices[0]))
    targets.append((f"dearest shop cosmetic ({fmt(prices[-1])})", prices[-1]))
    targets.append((f"every shop cosmetic ({len(prices)} of them, {fmt(sum(prices))})", sum(prices)))
    print(f"  {'':62}" + "".join(f"{name:>22}" for name in incomes))
    for label, price in targets:
        print(f"  {label:62}" + "".join(
            f"{hours(hours_to(data, inc, price)) + ' / ' + hours(hours_to(data, inc, price, True)):>22}"
            for inc in incomes.values()))
    print(f"  Buying also waits on the shelf. A rotation is {data.rotation_seconds // 60} min; the dearest shop cosmetic of each kind:")
    for kind in ("GunSkin", "Aura", "Accessory", "Parachute"):
        chance = on_sale(data, kind)
        item = max((k for k in chance), key=lambda k: data.shop[k]["price"])
        print(f"    {data.shop[item]['name']:22} {kind:9} {fmt(data.shop[item]['price']):>7} coins, on sale "
              f"{chance[item] * 100:.1f}% of rotations: about {wait_minutes(data, chance[item]):.0f} min to wait for it")
    print()
    print("  A crate exclusive, by its cheapest coin route (average coins, net of what the crate's brainrots sell for):")
    exclusives = sorted((k for k, v in data.crate_pool.items() if v.get("crateOnly")),
                        key=lambda k: (RARITIES.index(data.crate_pool[k]["rarity"]), k))
    mid = incomes["wins sometimes"]
    for item_id in exclusives:
        item = data.crate_pool[item_id]
        route = cheapest_route(data, item_id)
        if route:
            tier, opens, coins = route
            print(f"    {item['name']:22} {item['rarity']:9} {item['kind']:9} {data.crates[tier]['name']:20} "
                  f"{opens:7,.0f} opens {fmt(coins):>12} coins = {hours(coins / mid.sold)} sold, {hours(coins / mid.cash)} cash (wins sometimes)")
    print()

    print("4. WHERE THE CURVE BREAKS")
    print("  What a coin spent on a brainrot crate comes back as, if every pull is sold (a new profile, 1x luck):")
    print("    " + ", ".join(f"{data.crates[t]['name']} {sell_value(data, t) / data.crates[t]['coinPrice'] * 100:.0f}%"
                         for t in data.crate_order if isinstance(data.crates.get(t), Table)
                         and data.crates[t].get("coinPrice") and data.crates[t].get("category", "Brainrot") == "Brainrot"))
    shop_total = sum(v["price"] for v in data.shop.values())
    routes = {k: cheapest_route(data, k) for k, v in data.crate_pool.items() if v.get("crateOnly")}
    routes = {k: r for k, r in routes.items() if r}
    near = min(routes, key=lambda k: routes[k][2])
    far = max(routes, key=lambda k: routes[k][2])
    for name, inc in incomes.items():
        done = hours_to(data, inc, shop_total)
        print(f"  {name}: owns every shop cosmetic after {hours(done)} ({done / HOURS_PER_DAY:.0f} days at "
              f"{HOURS_PER_DAY} h); after that coins buy only crates and Rot Vendor items. The nearest crate exclusive, "
              f"{data.crate_pool[near]['name']}, is {hours(routes[near][2] / inc.sold)} of play selling everything; the furthest, "
              f"{data.crate_pool[far]['name']}, {hours(routes[far][2] / inc.sold)} ({routes[far][2] / inc.sold / HOURS_PER_DAY:.0f} days).")
    print("  The one other sink is the Rot Vendor, mid-match: " + ", ".join(
        f"{v['label'].title()} {v['price']}" for v in data.vendor) + " coins (VendorService.Products).")
    mid = incomes["wins sometimes"]
    print("  A set bonus is paid for owning every brainrot of a rarity at once. By coin crates (net of selling the rest,"
          " the middle profile's selling rate) against buying the set outright:")
    for rarity in ("Legendary", "Mythic", "Secret"):
        route = set_route(data, rarity)
        price = data.brainrot_prices.get(rarity)
        count = len(data.brainrots[rarity])
        if route:
            tier, opens, coins = route
            print(f"    {rarity:9} bonus {fmt(data.set_bonus[rarity]):>9} ({data.set_bonus.at(rarity)}): {opens:,.0f} "
                  f"{data.crates[tier]['name']}s, {fmt(coins)} coins net = {hours(coins / mid.sold)}; or {count} x {price} R$ "
                  f"= {fmt(count * price)} R$ outright")
    print()

    print("5. WHAT A ROBUX IS WORTH")
    rate, rate_at, goods, bundles, brainrots, passes = robux_sections(data, incomes)
    print(f"  The game's own exchange rate is its best coin pack: {rate:.0f} coins per R$ ({rate_at}).")
    print(f"  Hours = hours of play for the same coins, cash only (nothing sold).")
    print(f"  {'coins and crates':28} {'R$':>5} {'coins':>9} {'coins/R$':>9} {'vs pack':>8}" + "".join(f"{k:>16}" for k in incomes))
    for name, price, coins, where in goods:
        ratio = coins / price / rate
        flag = "   <- out of line" if ratio > 1.5 or ratio < 0.67 else ""
        print(f"  {name[:28]:28} {price:5} {fmt(coins):>9} {coins / price:9.0f} {ratio:7.2f}x"
              + "".join(f"{hours(coins / inc.cash):>16}" for inc in incomes.values()) + flag)
    print("  (a crate's coins are its coin price; the Super Crate has none, so it is what its pulls sell for)")
    print()
    for b in bundles:
        claim = f"the card says worth {fmt(b['claim'])} R$" if b["claim"] else "no worth claimed"
        print(f"  {b['name']} ({b['price']} R$): {fmt(b['coins'])} coins at coin prices ({b['coins'] / b['price']:.0f}/R$, "
              f"{b['coins'] / b['price'] / rate:.1f}x the pack); the same things cost {fmt(b['robux'])} R$ in this shop"
              f"{' plus ' + ', '.join(b['unpriced']) + ' (not sold alone)' if b['unpriced'] else ''}; {claim} ({b['where']})")
    print()
    print(f"  {'brainrot for Robux':18} {'R$':>5} {'sells for (mean / dearest)':>28} {'dearest coins/R$':>17}   "
          f"{'whole set':>9} {'set R$':>7} {'set bonus':>10} {'bonus+sell per R$':>18}")
    for b in brainrots:
        per = b["max"] / b["price"]
        flag = "   <- out of line" if per / rate > 1.5 else ""
        print(f"  {b['rarity']:18} {b['price']:5} {fmt(b['mean']) + ' / ' + fmt(b['max']):>28} {per:17.0f}   "
              f"{b['count']:9} {fmt(b['set_robux']):>7} {fmt(b['set_bonus']):>10} {(b['set_bonus'] + b['set_sell']) / b['set_robux']:18.0f}{flag}")
    print()
    for name, price, basis, extra, where in passes:
        print(f"  {name} ({price} R$, {where}): extra {basis} an hour " + ", ".join(
            f"{k} {fmt(v)}" for k, v in extra.items()) + "; pays back its price at the pack rate in "
              + ", ".join(f"{hours(price * rate / v) if v > 0 else 'never'}" for v in extra.values()))
    worth, reach = premium_pass(data, incomes)
    prem = data.passes["BrainrotPassPremium"]
    print(f"  {prem['name']} ({prem['suggestedPrice']} R$): {fmt(worth)} coins over its {data.pass_tiers} tiers "
          f"({worth / prem['suggestedPrice']:.0f}/R$), cosmetics uncounted; tier {data.pass_tiers} after "
          + ", ".join(f"{hours(h)}" for h in reach.values()) + ". The track never resets.")
    return incomes, findings, sold


# --- Planted faults ----------------------------------------------------------------------------------

def _copy(root):
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="economy_plant_"))
    for rel in SOURCES:
        (tmp / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(pathlib.Path(root) / rel, tmp / rel)
    return tmp


def _edit(tmp, rel, old, new):
    path = tmp / rel
    text = path.read_text(encoding="utf-8")
    if text.count(old) != 1:
        raise SystemExit(f"plant: {old!r} is not unique in {rel}")
    path.write_text(text.replace(old, new), encoding="utf-8")


def plant(root, n):
    base = Data(root)
    base_n = n or base.combatants
    results = []

    def check(name, ok, detail):
        results.append(ok)
        print(f"  {'FIRED' if ok else 'DID NOT FIRE'}: {name}. {detail}")

    # 1. A price moves the model by the amount predicted from first principles. The coins of the
    # bracket the loser lands in most are doubled; only the loser's share of that bracket, times
    # matches an hour, times the average placement multiplier, may move their cash an hour. A
    # prediction of zero would prove nothing, so the plant refuses one.
    tmp = _copy(root)
    loser = placements(PROFILES["loses only"], base_n)
    shares = {}
    for rank, s in loser.items():
        b = bracket_for(base, rank)
        shares[id(b)] = (shares.get(id(b), (b, 0))[0], shares.get(id(b), (b, 0))[1] + s)
    target, share = max(shares.values(), key=lambda bs: bs[1])
    text = (tmp / SHARED / "MatchConfig.lua").read_text(encoding="utf-8")
    line = re.search(rf"\{{ maxRank = {target['maxRank']},.*?coins = {target['coins']},", text).group(0)
    _edit(tmp, SHARED + "MatchConfig.lua", line, line.replace(f"coins = {target['coins']},", f"coins = {target['coins'] * 2},"))
    planted = Data(tmp)
    before = Income(base, PROFILES["loses only"], base_n)
    after = Income(planted, PROFILES["loses only"], base_n)
    predicted = (math.floor(target["coins"] * 2 * base.placement_factor) - math.floor(target["coins"] * base.placement_factor)) \
        * share * before.mph
    moved = after.cash - before.cash
    check(f"coins of the loser's usual bracket (rank <= {target['maxRank']}) doubled",
          predicted > 0 and abs(moved - predicted) < 0.5,
          f"loser cash/h moved {moved:+.1f}, predicted {predicted:+.1f} ({share:.2f} of their matches in that bracket)")

    # 2. A coin price moves its Robux exchange rate by exactly the ratio, in the direction predicted,
    # and trips the out-of-line flag.
    tmp = _copy(root)
    style = base.crates["Style"]["coinPrice"]
    _edit(tmp, SHARED + "CrateData.lua", f"coinPrice = {style},", f"coinPrice = {style * 3},")
    planted = Data(tmp)
    name = base.products["CrateStyle"]["name"]

    def style_rate(d):
        rate, _, goods, *_ = robux_sections(d, {k: Income(d, p, base_n) for k, p in PROFILES.items()})
        return next(c / r for n, r, c, _ in goods if n == name), rate
    (r0, pack), (r1, _) = style_rate(base), style_rate(planted)
    check("Style Crate coin price tripled", abs(r1 / r0 - 3) < 1e-9 and r1 / pack > 1.5,
          f"coins per R$ {r0:.0f} -> {r1:.0f} (x{r1 / r0:.2f}), {r1 / pack:.2f}x the pack, flagged")

    # 3. The invariant: every chance a player reads beside a crate is one the code rolls. A wrong
    # number on the Rare Crate must be caught at 1x luck, where nothing excuses it...
    tmp = _copy(root)
    rare = base.crates["Rare"]["description"]
    _edit(tmp, SHARED + "CrateData.lua", f'"{rare}"', '"Uncommon to Legendary, with a slim 9% shot at a Legendary."')
    hits = [f for f in odds_audit(Data(tmp)) if f["label"] == "Rare Crate card" and f["luck"] == 1]
    check("a wrong chance written on the Rare Crate", len(hits) == 1, f"{len(hits)} finding(s) at 1x luck")
    # ...and a crate whose text states no chance at all must produce no text finding (the check is not
    # just flagging every description it reads).
    tmp = _copy(root)
    for tier, crate in base.crates.items():
        if isinstance(crate, Table) and crate.get("description"):
            _edit(tmp, SHARED + "CrateData.lua", f'"{crate["description"]}"', f'"{tier} crate."')
    text_hits = [f for f in odds_audit(Data(tmp)) if f["kind"] == "text" and "Crate card" in f["label"]]
    check("no chance stated, nothing flagged", not text_hits, f"{len(text_hits)} card text finding(s)")

    # 4. An accessory chance on a crate that can only roll rarities with no accessories must be caught:
    # the card would promise what never comes out.
    tmp = _copy(root)
    _edit(tmp, SHARED + "CrateData.lua", "robuxOnly = true,", "robuxOnly = true,\n\t\taccessoryChance = 10,")
    hits = [f for f in odds_audit(Data(tmp)) if f["kind"] == "accessory" and f["label"] == "Super Crate card"]
    check("accessory chance on a crate with no accessories to give", bool(hits) and hits[0]["rolls"] == 0,
          f"{len(hits)} finding(s), real rate {hits[0]['rolls'] if hits else '?'}%")

    # 5. The Robux Shop scan reads the screen, not a constant: odds drawn there clear it.
    tmp = _copy(root)
    _edit(tmp, "StarterPlayerScripts/MenuClient.client.lua", "local function renderRobuxShop()\n",
          "local function renderRobuxShop()\n\tlocal _ = CrateData.OddsLine\n")
    planted = Data(tmp)
    check("odds drawn on the Robux Shop", planted.shop_draws_odds["renderRobuxShop"] and not base.shop_draws_odds["renderRobuxShop"],
          f"renderRobuxShop draws odds: before {base.shop_draws_odds['renderRobuxShop']}, after {planted.shop_draws_odds['renderRobuxShop']}")

    # 6. The team modes are held to 1.25-1.6x the battle royale's hour. A team win paying three times over
    # must put somebody above the band, and a loss paying nothing must put the player who never wins below
    # it; the unplanted build must be inside it (the band is not simply always failing).
    incomes = {k: Income(base, p, base_n) for k, p in PROFILES.items()}
    clean = [r for r in team_comparison(base, incomes) if not r[5]]
    for label, old, new in (("team win coins tripled", f"coins = {base.team['win']['coins']}, xp",
                             f"coins = {base.team['win']['coins'] * 3}, xp"),
                            ("team loss pays no coins", f"loss = {{ crate = \"{base.team['loss']['crate']}\", coins = {base.team['loss']['coins']},",
                             f"loss = {{ crate = \"{base.team['loss']['crate']}\", coins = 0,")):
        tmp = _copy(root)
        _edit(tmp, SHARED + "MatchConfig.lua", old, new)
        planted = Data(tmp)
        out = [f"{m} {n} coins x{c:.2f} XP x{x:.2f}" for m, n, _, c, x, ok in
               team_comparison(planted, {k: Income(planted, p, base_n) for k, p in PROFILES.items()}) if not ok]
        check(label, bool(out) and not clean, f"{len(out)} of 6 out of band ({'; '.join(out[:2])}); unplanted {len(clean)} out")

    print(f"economy_model plant: {sum(results)} of {len(results)} planted faults fired")
    return all(results)


def main():
    args = sys.argv[1:]
    root = next((a for a in args if not a.startswith("--") and not a.isdigit()), ".")
    n = None
    if "--combatants" in args:
        n = int(args[args.index("--combatants") + 1])
    if "--plant" in args:
        sys.exit(0 if plant(root, n) else 1)
    data = Data(root)
    incomes, *_ = report(data, n or data.combatants)
    # The one hard rule the model enforces: no team mode out of the battle royale's band (s.2b).
    if any(not r[5] for r in team_comparison(data, incomes)):
        sys.exit("economy_model: a team mode pays outside the battle royale's band (s.2b)")


if __name__ == "__main__":
    main()
