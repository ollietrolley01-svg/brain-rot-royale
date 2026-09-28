# The economy, end to end (task 07)

Written 2026-09-22 against `main` at `9124ce2`. Everything below is in the branch `task/economy-model`,
not landed. The numbers come from `tools/economy_model.py`, which reads the game's data files and cites
the file and line of every number it uses. Rerun it after any price change:

```
python tools/economy_model.py .                   # the field size MatchConfig says (30 today)
python tools/economy_model.py . --combatants 50   # the 50-player battle royale Oliver asked for (#127)
python tools/economy_model.py . --plant           # the planted faults
```

`main` still fills every mode to `BotFillTarget = 30` (`MatchConfig.lua:101`). OLIVER_LIST #127 says the
build machine now fills the battle royale to 50 through a new `BotFillTargetBattleRoyale`. The model reads
that field when it lands, so its default follows the build with no edit. Both sizes are reported below
because the placement brackets were written for 50, and the difference matters for a player who loses.

## 1. The most important finding: odds a player reads that the code does not roll

The roll itself is sound. `CrateService.Open` rolls with `CrateData.EffectiveOdds` at the same luck the
card was drawn with, and it refuses the open if the two differ (`CrateService.lua:155`). Pity only ever
raises the chance of its own rarity, so the per-roll odds on a card are never better than what a player
gets. The three jackpot figures written in crate text (60%, 25%, and 50K to 250K) match the data. A
brute-force simulation of `Open` (400,000 opens a case, five crate and luck cases) agreed with the
model's pity, accessory and sell-value maths to within sampling noise.

The problems are in what the player reads around the roll. There are three, in order of weight.

### 1a. The Robux Shop sells twelve paid random items with no odds on screen

`renderRobuxShop` (`MenuClient.client.lua:2215`) lists crate products as a name, the product description
and a price button (`MenuClient.client.lua:2293-2297`). The featured cards (`featuredCard`,
`MenuClient.client.lua:2054`) show the description or the bundle contents, a "worth" line and a price.
Neither calls `CrateData.OddsLine`. The purchase prompt opens straight from those screens, so a player
can pay Robux for these without seeing any odds:

| Sold on | Items |
|---|---|
| featured cards | Starter Bundle 300 R$ (holds 4 crates), Pro Bundle 800 R$ (holds 5), Super Crate 999 R$ |
| product rows | Common 5, Uncommon 10, Rare 35, Epic 135, Legendary 499, Mythic 899, Style 69, Deluxe Style 199, Prestige Style 449 (R$) |

The Crates and Style Crates tabs do show correct odds, and a player can buy from there too. The Robux
Shop is a second way to buy that skips them. **None of this is live yet**: every product `id` is still 0,
and `shopVisible` hides products without an id (`MenuClient.client.lua:2016`). It goes live the day the
ids are pasted in, so it wants fixing before that.

Proposed fix, for whoever owns `renderRobuxShop` (it is not mine to edit). In the product loop, add the
odds line for any product that grants a crate:

```lua
-- before (MenuClient.client.lua:2293)
for _, product in ipairs(products) do
	local buttons = makeRow(nextOrder(), product.name, C.Text, product.description)

-- after
for _, product in ipairs(products) do
	local grantCrate = product.grant.kind == "Crate" and CrateData.Get(product.grant.crate)
	local subtitle = product.description
	if grantCrate then
		subtitle = subtitle .. "\n" .. table.concat(CrateData.OddsLine(grantCrate, profile and profile.crateLuck or 1, false), "   ")
	end
	local buttons = makeRow(nextOrder(), product.name, C.Text, subtitle)
```

A crate bought for Robux is always a paid crate, so Beginner's Luck can never apply to it and `false` is
the right `boosted`. `makeRow`'s subtitle height has not been checked for two lines, and the Super Crate's
featured card and the two bundles need the same line added in `featuredCard`. Both need a render, which
is the coordinator's to run. The planted fault 5 below confirms the model notices when this is done.

### 1b. Crate text states fixed percentages that are wrong whenever a player has 2x luck

The card's odds line follows the player's luck. The description printed on the same card does not. A
player has 2x luck with the 2x Crate Luck pass, or for 24 hours after the Daily Spin lands on "pass for a
day" and picks that pass. At 2x the card then contradicts itself:

| Where | Text | Rolled at 2x luck |
|---|---|---|
| Super Crate card, `CrateData.lua:39` | "10% Secret" | Secret 19.00% |
| Rare Crate card, `CrateData.lua:69` | "a slim 3% shot at a Legendary" | Legendary 5.91% |
| Epic Crate card, `CrateData.lua:79` | "a Legendary about one time in eight" | Legendary 22.08% (26.04% with Mythic) |
| Legendary Crate card, `CrateData.lua:90` | "a third Legendary" | Legendary 51.00% |
| Mythic Crate card, `CrateData.lua:99` | "17% Mythic, 3% Secret" | Mythic 30.09%, Secret 5.91% |
| Mythic Crate, Robux Shop, `GamepassConfig.lua:214` | "17% Mythic, 3% Secret" | Mythic 30.09%, Secret 5.91% |

All six are correct at 1x. The Mythic Crate's Robux text is the worst case because it is the only odds a
Robux Shop buyer sees (1a). The fix is to take the numbers out of the prose, since the odds line beside it
already carries them. Before and after, in the game's voice (these files are not mine, so this is for the
coordinator to route):

| File:line | Before | After |
|---|---|---|
| `CrateData.lua:39` | `Mythic or Secret every time, 10% Secret, 60% chance of a 50K-250K jackpot.` | `Mythic or Secret every time, and a 60% chance of a 50K-250K jackpot.` |
| `CrateData.lua:69` | `Uncommon to Legendary, with a slim 3% shot at a Legendary.` | `Uncommon to Legendary, with a slim shot at a Legendary.` |
| `CrateData.lua:79` | `Rare to Mythic. Nothing below a Rare, and a Legendary about one time in eight.` | `Rare to Mythic. Nothing below a Rare, and a real shot at a Legendary.` |
| `CrateData.lua:90` | `Epic to Secret: a third Legendary, a small shot at Mythic, and a 25% coin jackpot.` | `Epic to Secret: plenty of Legendaries, a small shot at Mythic, and a 25% coin jackpot.` |
| `CrateData.lua:99` | `Legendary or better, every time. 17% Mythic, 3% Secret.` | `Legendary or better, every time, with a shot at Mythic and Secret.` |
| `GamepassConfig.lua:214` | `One Mythic loot crate: Legendary or better every time, 17% Mythic, 3% Secret.` | `One Mythic loot crate: Legendary or better every time.` |

The jackpot figures stay because luck never touches a jackpot. The GamepassConfig change only makes
sense together with 1a: without the odds line on that row, removing the numbers leaves the Robux buyer
with nothing.

### 1c. "+ N% accessory" is a ceiling that falls as a player collects, and the accessory replaces the brainrot

`CrateData.OddsLine` prints `+ 18% accessory` on the Legendary Crate (`CrateData.lua:276`). What
`CrateService.Open` does (`CrateService.lua:227-247`) is different in two ways:

- The accessory **replaces** the brainrot. The "+" reads as a bonus on top.
- It only happens if the player has an unowned accessory at the rarity rolled. No accessory is Mythic or
  Secret, so a Mythic or Secret roll never gives one, and once a player owns a rarity's accessories that
  rarity stops giving them too.

For a new profile the real rate is below the printed one on two crates, and on every crate it falls to
zero as the player collects:

| Crate | Printed | New profile, 1x | New profile, 2x |
|---|---|---|---|
| Epic, `CrateData.lua:76` | + 14% | 13.72% | 13.45% |
| Legendary, `CrateData.lua:86` | + 18% | 16.51% | 15.23% |
| Common, Uncommon, Rare | + 6, 8, 10% | the same, until the player owns those accessories | |

This is a product decision, so there are two options rather than a fix:

1. **Print the player's real rate.** Give `OddsLine` the player's owned cosmetics, work out
   `accessoryChance × P(rolled rarity has an unowned accessory)` at their luck, and print
   "14% chance of an accessory instead" (or "no accessories left" at zero). This matches the rule already
   applied to rarity odds, that the number on screen is the number rolled.
2. **Change the roll so the printed number is true.** When no accessory is left at the rolled rarity,
   fall back to an unowned accessory of any rarity. This changes what crates pay out, so it is Oliver's
   call.

Either way, "+" should become "instead", because the current wording describes a bonus the code does
not give.

## 2. How many coins an hour of play produces

The player is an assumption; everything else is read from the files. The three profiles are in
`PROFILES` at the top of the model:

| Profile | Assumption |
|---|---|
| loses only | never wins, always in the bottom 60% of the field, 0.5 bot kills a match |
| wins sometimes | wins 1 match in 25, otherwise anywhere in the field, 2 bot kills a match |
| strong | wins 1 in 5, otherwise always in the top 40%, 5 bot kills a match |

Also assumed: a solo player in a server of bots (a solo player's match ends when they die, so a weak
player plays more, shorter matches); 2 hours a day, every day, at the Daily Spin's streak cap; 20 seconds
to load the map and land, which nobody has measured. The lobby gap between matches is 73 seconds
(`ResultsDuration + Intermission + AllReadyCountdown + DropSelectSeconds` in `MatchConfig.lua`). Each
player dies at a time in the 322-second storm schedule proportional to where they placed.

"Cash" is coins the player holds without selling anything: placement and kill coins, crate jackpots,
and the day's quests, spin and weeklies spread over the day's 2 hours. "If sold" adds every brainrot
pulled from those crates sold at its `coinValue`.

| Profile | 50 combatants: matches/h | match coins/h | cash/h | if sold/h | 30 combatants: cash/h | if sold/h |
|---|---|---|---|---|---|---|
| loses only | 18.8 | 1,790 | 4,916 | 12,633 | 6,836 | 17,172 |
| wins sometimes | 13.8 | 8,129 | 11,802 | 35,952 | 13,745 | 43,372 |
| strong | 9.8 | 18,736 | 22,409 | 71,455 | 24,135 | 79,980 |

**Is it fair to the player who only loses?** From matches alone, not very, and it gets worse at 50. The
losing player makes 30 match coins a minute against the middle player's 135 (4.5 times less). At 30
combatants it is 62 against 168 (2.7 times). The reason is the brackets (`MatchConfig.lua:81`): at 50,
ranks 31 to 50 pay 60 coins and a Common Crate, and a player in the bottom 60% spends two thirds of their
matches there. At 30 those ranks do not exist and the same player lands in the 100 and 260 brackets.

What keeps the losing player's hour from collapsing is the daily layer. Quests, the Daily Spin and the
weeklies are worth 3,126 coins an hour of a 2-hour day, which is 64% of that player's cash at 50
combatants. That money does not grow with more play: a player who plays 4 hours a day gets half as
much of it per hour. The losing player also misses some quests outright. They cannot finish "Win a
match", either top-10 quest, or "Eliminate 25", so they get the daily bonus Epic Crate on 57% of days.

**Selling is the biggest coin source in the game.** For every profile, selling what the crates give pays
2.6 to 4.3 times what the matches pay directly. A Legendary brainrot sells for 17,063 coins on average
and a Secret for 441,667 (`BrainrotData.lua`), next to 2,500 coins for a win. So "earning coins" and
"keeping a collection" pull against each other, and a player who keeps their brainrots lives on the cash
column.

**Lobby football can pay more than losing.** A goal on the lobby pitch pays 35 coins
(`Bootstrap.server.lua:445`) at most once per 20 seconds (`LobbyService.lua:2224`). A player who never
readies is never pulled into a match, so they can keep scoring. The ceiling is 6,300 coins an hour, more
than the losing player's 4,916 at 50 combatants. The ceiling assumes a goal every 20 seconds, which
nobody has measured. A probe timing real goals would settle whether it can be reached.

### 2b. The team modes pay more than the battle royale, on purpose

Team Deathmatch and Objective Capture used to pay nothing. They now pay an itemised card
(`MatchConfig.TeamModeRewards`, `RewardService.TeamBreakdown`): a crate and coins for the result (a loss
included), kills at the battle royale's rate up to 45 a match, assists, multi-kills, revenge, the
objective lines in Objective Capture, and pay per minute of active play. On top of that there is a
TEAM BONUS the battle royale has no equivalent for: the team MVP (2,000 coins), the first team win of the
day (an Epic Crate and 1,500 coins), a win streak across consecutive team matches, and four team-only
cosmetics for lifetime team wins (3, 10, 25, 50).

Oliver asked for them to be clearly worth playing ("team gamemodes need better rewards!! make them worth
playing"), so the target is 1.3 to 1.5 times the same player's battle royale hour, in coins and in Pass
XP, for every profile. `tools/economy_model.py` s.2b checks all twelve numbers and exits 1 if any leaves
1.25 to 1.6. Coins an hour / XP an hour, as a multiple of the battle royale's:

| profile | Team Deathmatch | Objective Capture |
|---|---|---|
| loses only | 1.41 / 1.50 | 1.51 / 1.49 |
| wins sometimes | 1.37 / 1.35 | 1.47 / 1.34 |
| strong | 1.27 / 1.51 | 1.32 / 1.46 |

Task 18 (2026-09-25) took both team clocks from 8 to 12 minutes. The result pay and every per-match cap in
`TeamModeRewards` were scaled by 720/480 with them (`matchSeconds = 720` says which clock they are sized
for), and the model scales its per-match profile counts the same way. With the clocks moved and the pay
left alone, all six rows fell to 0.98-1.11 (0 of 6 in band). The model now fails if a team mode's
`timeLimit` and `matchSeconds` disagree.

The profiles for the team modes are assumptions stated in the model (kills, win rate, MVP rate, time
active), not measurements. Two things the ratio leaves out. The milestone cosmetics have no coin value.
And crates: a team hour holds about 4.5 of them against the battle royale's 10 to 19, so a player who sells
every pull earns a little less than in the battle royale when losing (11.7k against 12.4k an hour) and less
when winning (25k against 35k, 39k against 70k). The lead is in coins and XP, not in crate volume.

The new team quests (play, win, assists, captures, MVP) share the daily pool, so a player who only plays
the battle royale draws a quest they will not finish a little more often: the losing player's cash an hour
moved from 5,431 to 5,213.

## 3. How long until a player can afford each thing

Hours of play at 50 combatants, cash first and then selling every pull. The model also counts the one-off
coins that arrive along the way: the free pass track and the achievements it has a rate for (kills, wins,
matches, top 10s, crates earned).

| Target | Coins | loses only | wins sometimes | strong |
|---|---|---|---|---|
| first Common Crate | 500 | 4 min / 2 min | 2 min / 1 min | 1 min / 0 min |
| Epic Crate | 20,000 | 3.2 h / 1.3 h | 1.4 h / 32 min | 49 min / 16 min |
| Legendary Crate, the one everyone wants | 75,000 | 10.9 h / 5.5 h | 5.3 h / 1.9 h | 2.9 h / 1.0 h |
| Mythic Crate | 250,000 | 42.9 h / 17.5 h | 17.6 h / 6.6 h | 9.5 h / 3.3 h |
| Style Crate | 8,000 | 1.1 h / 35 min | 37 min / 13 min | 19 min / 6 min |
| dearest shop cosmetic (Crown of Rot) | 40,000 | 6.8 h / 2.8 h | 2.9 h / 1.1 h | 1.7 h / 32 min |
| every shop cosmetic (45) | 593,200 | 111 h / 43.9 h | 45.5 h / 15.4 h | 24.0 h / 7.8 h |

Coins are not the only wait. The Legendary Crate is on the shelf in 25% of 5-minute rotations and the
Mythic in 10% (`ShopRotation.lua:33`). The dearest shop cosmetics are rarer still, because the rotation
draws Epics at weight 9 against 100 for a Common (`ShopRotation.lua:29`). The model works out each
item's chance exactly:

| Item | Price | On sale | Average wait |
|---|---|---|---|
| Gold Sahur (gun skin) | 25,000 | 7.8% of rotations | 59 min |
| Crown of Rot (accessory) | 40,000 | 5.2% | 92 min |
| Sahur Aura | 30,000 | 4.6% | 104 min |
| Dragonwing (parachute) | 38,000 | 3.5% | 140 min |

**The cosmetic they saw somebody else wearing** is most likely a crate exclusive: those are the
Legendary, Mythic and Secret ones, and no shop sells them. The model finds the cheapest coin crate for
each one, assuming a player who owns nothing of that rarity yet (crates never repeat an item, so the one
wanted is equally likely to be any draw of its pool). The middle player, selling everything:

| Exclusive | Cheapest route | Opens | Coins | Hours |
|---|---|---|---|---|
| Magma Core (Legendary skin) | Gun Skin Crate | 25 | 187,500 | 5.2 h |
| Void Aura (Legendary) | Aura Crate | 17 | 333,333 | 9.3 h |
| Golden Halo, Galaxy Brain (Legendary accessories) | Accessory Crate | 50 | 500,000 | 13.9 h |
| Glitch (Mythic skin) | Gun Skin Crate | 125 | 937,500 | 26.1 h |
| Galaxy Manta (Secret parachute) | Parachute Crate | 250 | 3,750,000 | 104 h |
| Starlight (Secret aura) | Aura Crate | 250 | 5,000,000 | 139 h |

## 4. Where the curve breaks

**Where earning stops mattering.** A player owns every shop cosmetic after 111 hours if they only lose,
46 if they win sometimes, and 24 if they are strong. At 2 hours a day that is 56, 23 and 12 days. After
that, coins buy only crates and Rot Vendor items, and a brainrot crate is a loss in coins. Sold back, a
coin spent comes back as 50% on the Common Crate, 37% on the Uncommon, 32% Rare, 24% Epic, 26%
Legendary and 27% Mythic. This is how the game stops crates being a coin printer (`verify.py` checks
that no crate is profitable). It also means that past the shop, a coin only matters as a crate pull.
The one other thing coins buy is the Rot Vendor mid-match: a Med Kit for 250, a Shield Potion for 300
and an Ammo Refill for 150 (`VendorService.Products`).

**Where the next thing is too far away.** The Secret exclusives sit at 104 to 139 hours for the middle
player and 396 hours for the losing one (about 200 days at 2 hours). The set bonuses go further. A set
bonus pays for owning every brainrot of a rarity at once (`BrainrotData.lua:376`). The cheapest coin
route for each, net of selling everything else:

| Set | Bonus | Coin route | Middle player | Or buy the set outright |
|---|---|---|---|---|
| Legendary (16) | 200,000 | 2,003 Rare Crates, 6.8M coins net | 190 h | 16 × 600 = 9,600 R$ |
| Mythic (10) | 1,000,000 | 1,464 Epic Crates, 22.2M net | 616 h | 10 × 1,100 = 11,000 R$ |
| Secret (6) | 4,000,000 | 383 Mythic Crates, 70.2M net | 1,952 h | 6 × 2,000 = 12,000 R$ |

A player cannot finish the Secret set by playing. Buying it takes 12,000 R$, and it then pays back more
coins than any coin pack would give (section 5).

## 5. What a Robux purchase is worth

The game's own exchange rate is its best coin pack, 50,000 coins for 399 R$, which is 125 coins per R$
(`GamepassConfig.lua:272`). Every other item is compared with that rate. Hours are hours of play for the
same coins, without selling, at 50 combatants.

| Item | R$ | Worth in coins | Coins per R$ | Against the pack | Hours: loses / middle / strong |
|---|---|---|---|---|---|
| Common Crate | 5 | 500 | 100 | 0.80x | 6 min / 3 min / 1 min |
| 10,000 SahurCoins | 99 | 10,000 | 101 | 0.81x | 2.0 / 0.9 / 0.5 h |
| Style Crate | 69 | 8,000 | 116 | 0.93x | 1.6 h / 41 min / 21 min |
| Deluxe Style Crate | 199 | 25,000 | 126 | 1.00x | 5.1 / 2.1 / 1.1 h |
| Prestige Style Crate | 449 | 60,000 | 134 | 1.07x | 12.2 / 5.1 / 2.7 h |
| Rare, Epic, Uncommon, Legendary Crates | 35 to 499 | their coin price | 143 to 150 | 1.14x to 1.20x | Legendary: 15.3 / 6.4 / 3.3 h |
| **Super Crate** | 999 | 200,227 (pulls sold; no coin price) | 200 | **1.60x** | 40.7 / 17.0 / 8.9 h |
| **Mythic Crate** | 899 | 250,000 | 278 | **2.22x** | 50.9 / 21.2 / 11.2 h |

A crate's worth is its coin price, since that is what the same crate costs a player who plays for it.

**Out of line, cheap for what it is.**
- **Mythic Crate, 899 R$.** At the pack rate its coin price is 2,000 R$. Every other crate sits within
  20% of the pack; this one is 2.2 times. Either 899 is a deliberate deal or the crate should cost about
  1,800 to 2,000 R$. That is Oliver's call.
- **Super Crate, 999 R$.** It has no coin price, but what it gives sells for about 200,000 coins
  (Mythic 90%, Secret 10%, a 60% jackpot of 50K to 250K), 1.6 times the pack.
- **A Secret brainrot, 2,000 R$.** The dearest sells for 600,000 coins, 300 coins per R$, which is 2.4
  times the pack. It gets worse with a whole set. Six Secrets cost 12,000 R$, sell for 2.65M and pay the
  4M set bonus, so 6.65M coins for 12,000 R$ comes to 554 per R$ (4.4 times the pack). The set bonus goes through
  `EarnCoins` (`RewardService.lua:144`), so 2x SahurCoins doubles it to 8M. A player who wants coins
  should buy Secret brainrots and sell them, never the coin pack. Nothing stops a Robux-bought brainrot
  being sold: it goes into the ordinary collection (`BrainrotShopService.lua:219`).

**Out of line, dear for what it is.**
- **The 10,000-coin pack and the Common Crate** are both 20% worse than the 50,000 pack. That is normal
  for a small pack.
- **The Style Crate** is 7% worse bought for Robux than buying the pack and converting. The comment
  that priced it says the Style tiers are "about 15% better than converting" (`GamepassConfig.lua:229`).
  Against the 50,000 pack the three tiers are 7% worse, even and 7% better.

**Bundles and the "worth" on their cards.** The Pro Bundle card says "Worth 7,000+ R$ • 8x value"
(`GamepassConfig.lua:127`). Priced at the Robux prices of this same shop, its coins and crates cost
4,194 R$. Its 5 HealthPro and 5 SpeedPro boosts and two exclusives are not sold alone, so they have no
price to add. Reaching 7,000 needs the two Mythic Crates counted at their coin price (2,000 R$ each at
the pack rate) rather than the 899 R$ the shop charges for them. The Starter Bundle's "Worth 1,200+ R$"
(`GamepassConfig.lua:102`) is 974 R$ at shop prices plus the StarterSpark exclusive, so it holds only if
the exclusive is worth 226 R$ or more. For a young audience, a "worth" line is a claim about money. I
would state it at the shop's own prices, or drop the figure.

**Passes, which pay per hour rather than once.**
- **2x SahurCoins, 350 R$.** Worth 43,750 coins at the pack rate. It pays that back in 8.9, 4.5 and
  2.9 hours of play for the three profiles. Anyone who plays more than a few hours gets far more from it
  than from a coin pack.
- **2x Crate Luck, 350 R$.** Its value only shows if the player sells: 4,473 to 31,002 extra coins an
  hour selling everything, which pays back in 1.4 to 9.8 hours. It adds nothing to cash, because
  jackpots do not use luck.
- **Brainrot Pass Premium, 450 R$.** 271,000 coins in coins and crates over 50 tiers, plus cosmetics,
  reached after 24.3, 12.1 and 7.9 hours. It is priced as a season pass ("runs the length of a season",
  `GamepassConfig.lua:81`), but no season exists. Nothing resets `Pass.xp` or the claimed tiers, so
  a buyer gets 50 tiers once per account and nothing after tier 50.

## 6. What I would change and what I would leave

**`ProgressionData.lua`: leave it.** It is coherent with the rest of the economy. The Cell Shop's
brainrots turn Brain Cells into coins at 1.9 coins a Cell (2,160 Cells a day buys 4,060 coins of
brainrots), but Cells come in at 111 to 263 an hour (`tools/progression_model.py`), so the pipe is worth
a few hundred coins an hour at most. The rank crates (four Rare and one Epic a prestige) sell for about
11,000 coins a prestige, which is 16 to 38 hours of play: noise next to placements. Its Cell Shop never
sells Legendary or better, and `verify.py` already holds that.

**`AchievementData.lua`: leave it.** 36 achievements pay 195,200 coins in total, which is 17 hours of
the middle player's income, spread over hundreds of hours. No achievement pays enough to change a
purchase decision, and none can be farmed: each pays once.

**Outside my files**, the changes I would make are all in section 1 (odds, with the exact text), and I
would put the rest to Oliver as decisions rather than make them:

1. Draw the odds on the Robux Shop and the featured cards before any product id is pasted in (1a).
2. Take the fixed percentages out of the crate text (1b, text above).
3. Make the accessory figure true, one of the two ways in 1c.
4. Decide whether the Mythic Crate at 899 R$ and the Super Crate are meant to be deals.
5. Decide whether buying Secret brainrots with Robux should be sellable at full `coinValue` and count
   toward the 4M set bonus. As it stands, that is the best way to buy coins in the game.
6. Restate or drop the bundle "worth" figures.
7. Decide whether lobby goals should keep paying when the player never readies.
8. Look again at the bottom brackets at 50 combatants. A losing player's placement coins average 75 a
   match at 50 and 176 at 30, because the brackets for ranks 31 to 50 pay 60.

## 7. How the model works, and what it proves

It reads 17 sources and finds all 17; the list with what each gives is `SOURCES` at the top of the
script. A small reader parses the Lua table constructors and keeps the line of every key, which is how
each printed figure carries its file and line. When a price, a weight or a table moves, the output moves
with it.

**Looked for and not found.** The brief names "streak and playtime rewards". There is no playtime reward
anywhere. The login streak exists only as the Daily Spin's coin multiplier. The 7-day login table
`BattlePassData.DailyRewards` (`BattlePassData.lua:37`) pays nothing: its only reader is StateSync's
`nextIndex` (`StateSync.lua:98, 153`), and no client reads that. The live Robux prices are on the
Creator Dashboard, so the model uses `suggestedPrice`, which the shop displays. Respawn-mode pay is a
placeholder of 0.

**Planted faults** (`--plant`, 6 of 6 fire at both field sizes). Each one edits a copy of the sources in
a temp directory, never the repo:

1. Doubling the coins of the bracket the losing player lands in most moves their cash an hour by exactly
   the predicted amount (+778.7 at 50 combatants, +1,081.2 at 30). The plant refuses a prediction of
   zero. An earlier draft aimed at the bottom bracket, and at 30 combatants that bracket is out of reach,
   so the "check" passed while proving nothing.
2. Tripling the Style Crate's coin price triples its coins per R$ exactly and trips the out-of-line flag.
3. A wrong chance written on the Rare Crate is caught at 1x luck. This one is aimed at the invariant
   (every chance a player reads is one the code rolls), not at today's findings, so it keeps working
   after they are fixed.
4. The control for 3: with every percentage removed from the crate text, the audit flags nothing.
5. An accessory chance on the Super Crate, which rolls only rarities with no accessories, is caught with a
   real rate of 0%.
6. The Robux Shop scan reads the screen's code rather than a constant. Adding an `OddsLine` call to
   `renderRobuxShop` clears it.

**Cross-check.** A separate brute-force simulation of `CrateService.Open` (roll, pity, the accessory
swap and the jackpot, 400,000 opens a case) matched the model to within sampling noise for Epic,
Legendary and Rare at 1x and Legendary and Super at 2x.

## 8. What this does not prove

- **The player profiles are assumptions**, and so are the 20-second load and the 2 hours a day. The
  shape (who earns what relative to whom) is sturdier than any single figure.
- **The match timing is a model.** It assumes deaths spread evenly across the storm schedule, and it has
  not been checked against a real match. Coins an hour scales with it directly.
- **A solo server of bots.** With other real players, a dead player waits for the match to end, which
  lowers matches an hour for anyone who dies early.
- **Not modelled:** kill-streak bonuses, bounties, Gold Rush, easter eggs, the Cloud Climb's 250 for a
  first clear per server, and every rank-based achievement. All of them add to good players more than
  weak ones, so the gap in section 2 is if anything understated.
- **"If sold" is a ceiling**, not a behaviour. Nobody knows how much players sell.
- **Nothing here is a render.** Whether the Robux Shop row has room for an odds line, and how the
  reworded card text reads on screen, is for the coordinator's gallery.
- **The lobby football ceiling is unmeasured.** Whether a player can score every 20 seconds needs a probe.
- **I state the brief's rule on odds, not Roblox's policy text.** I did not check the policy wording.

## 9. Found outside the brief (reported, not fixed)

- **`GamepassConfig.lua:15`**, the dashboard setup steps, lists "Brainrot Pass Premium 50 R$". The pass
  is priced 450 (`GamepassConfig.lua:83`), and the same step tells Oliver to set the dashboard price
  from this list. Followed as written, the pass would go on sale at 50 R$.
- **Premium pass is priced as a season pass, and no season exists** (section 5).
- **`BattlePassData.DailyRewards` is dead** (section 7).
- **`CrateData.lua:7`** says the Legendary Crate is "the first with any shot at Mythic and Secret". The
  Epic Crate rolls Mythic 2% (`CrateData.lua:77`).
- **`CrateData.lua:103`** gives the Style Crate pool sizes as "13 accessories, 15 auras, 22 gun skins, 15
  parachutes". What a crate can draw (`CosmeticData.OfKind`, which skips bundle and rank rewards) is 18
  accessories, 13 auras, 11 gun skins and 15 parachutes.
- **`CrateData.lua:14-16`** says the guaranteed pull is "the next one" after `every` dry opens. The code
  forces the `every`-th open itself (`CrateService.lua:206`). No player sees this since the card lost its
  pity counter, but the comment is off by one.
- **`GamepassConfig.lua:229`**, the Style Crate pricing comment, claims 15% better than converting
  (section 5).
- **`verify.py` is red on `main`** with the `climb_design` rounding coin-flip diagnosed in
  `coordination/messages/2026-09-21-2323-bimjom-task03-landed-and-the-verify-red-diagnosed.md`. Its
  output is identical with and without this branch.
