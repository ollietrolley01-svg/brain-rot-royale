"""Data and wiring consistency checks for Brain Rot Royale. Usage: python verify.py <project>"""
import os, re, sys

root = sys.argv[1] if len(sys.argv) > 1 else "."
problems = []

def read(rel):
    with open(os.path.join(root, rel), encoding="utf-8") as f:
        return f.read()

def lua_files():
    for base, _, files in os.walk(root):
        for name in files:
            if name.endswith(".lua"):
                path = os.path.join(base, name)
                yield os.path.relpath(path, root), open(path, encoding="utf-8").read()

# --- Luau's main-chunk local limit ----------------------------------------------
# Luau allows 200 locals per function, and a script's top level counts as a function. Nothing
# else in this pipeline can see that. It isn't a structural imbalance, so balance.py passes it;
# the file only fails when Luau itself compiles it, which is a seven-minute round trip through
# the harness. HudClient reached 202 and silently stopped compiling. This catches the next one
# in a second instead.
#
# Locals declared inside a do-block are released at its end, so that's the fix when this fires.
# Depth tracking matches balance.py: 'for' and 'while' aren't openers because their own 'do'
# already supplies the token, and 'elseif' is a single token so it never opens a second level.
LOCAL_LIMIT = 200
LOCAL_WARN = 195

def _strip_lua(src):
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        m = re.match(r'--\[(=*)\[', src[i:])
        if m:
            close = ']' + m.group(1) + ']'
            j = src.find(close, i)
            i = n if j < 0 else j + len(close)
            continue
        if src.startswith('--', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
            continue
        m = re.match(r'\[(=*)\[', src[i:])
        if m:
            close = ']' + m.group(1) + ']'
            j = src.find(close, i)
            i = n if j < 0 else j + len(close)
            out.append(' "" ')
            continue
        if c in '"\'`':
            q, i = c, i + 1
            while i < n:
                if src[i] == '\\':
                    i += 2
                    continue
                if src[i] == q:
                    i += 1
                    break
                i += 1
            out.append(' "" ')
            continue
        out.append(c)
        i += 1
    return ''.join(out)

def main_chunk_locals(src):
    depth = total = 0
    for line in _strip_lua(src).split('\n'):
        if depth == 0:
            m = re.match(r'\s*local\s+(.*)', line)
            if m:
                body = m.group(1)
                if body.startswith('function'):
                    total += 1
                else:
                    total += len([x for x in body.split('=')[0].split(',') if x.strip()])
        for t in re.findall(r'\b[A-Za-z_]\w*\b', line):
            if t in ('function', 'if', 'do'):
                depth += 1
            elif t == 'end':
                depth -= 1
    return total

_worst_count, _worst_file = 0, None
for _rel, _src in lua_files():
    _n = main_chunk_locals(_src)
    if _n > _worst_count:
        _worst_count, _worst_file = _n, _rel
    if _n >= LOCAL_WARN:
        problems.append(f"{_rel}: {_n} locals in the main chunk, Luau's limit is {LOCAL_LIMIT} — wrap some in a do-block")
print(f"main-chunk locals: most is {_worst_count} in {_worst_file} (limit {LOCAL_LIMIT})")

RARITIES = re.findall(r'"(\w+)"', re.search(r"Rarity\.Order = \{([^}]*)\}", read("ReplicatedStorage/Shared/Rarity.lua")).group(1))

# --- Brainrots ----------------------------------------------------------------
models = read("ReplicatedStorage/Shared/BrainrotModels.lua")
# The builder rigs companions by splitting stacked bodies at the neck, and CompanionAnimations nods
# the head group about the same height. They're kept apart so the builder needn't require the
# animation module, so check by hand that they still agree.
_necks = [re.search(name + r" = \{([^}]*)\}", text) for name, text in
          (("local CompanionNeck", models), (r"CompanionAnimations\.Neck", read("ReplicatedStorage/Shared/CompanionAnimations.lua")))]
if not all(_necks):
    problems.append("can't find CompanionNeck / CompanionAnimations.Neck to compare")
elif dict(re.findall(r"(\w+) = (-?[\d.]+)", _necks[0].group(1))) != dict(re.findall(r"(\w+) = (-?[\d.]+)", _necks[1].group(1))):
    problems.append(f"BrainrotModels CompanionNeck {_necks[0].group(1).strip()} != CompanionAnimations.Neck {_necks[1].group(1).strip()}")
extras_ok = set(re.findall(r'extra == "(\w+)"', models))
eyes_ok = set(re.findall(r'eyes == "(\w+)"', models)) | {"Round"}
mouth_ok = set(re.findall(r'mouth == "(\w+)"', models)) | {"None"}
body_ok = set(re.findall(r'^	(\w+) = \{ top = ', models, re.M))
print("vocab:", len(body_ok), "bodies,", len(eyes_ok), "eyes,", len(mouth_ok), "mouths,", len(extras_ok), "extras")
data = read("ReplicatedStorage/Shared/BrainrotData.lua")
attacks = set(re.findall(r"^\t(\w+) = \{", data.split("BrainrotData.Attacks")[1].split("\n}")[0], re.M)) if "BrainrotData.Attacks" in data else set()
names = []
for m in re.finditer(r'\{ name = "([^"]+)", rarity = "(\w+)".*?attack = "(\w+)".*?look = \{([^\n]*)\} \} \}', data, re.S):
    name, rarity, attack, look = m.groups()
    names.append(name)
    if rarity not in RARITIES: problems.append(f"brainrot {name}: bad rarity {rarity}")
    if attacks and attack not in attacks: problems.append(f"brainrot {name}: bad attack {attack}")
    body = re.search(r'body = "(\w+)"', look); eyes = re.search(r'eyes = "(\w+)"', look); mouth = re.search(r'mouth = "(\w+)"', look)
    if not body or body.group(1) not in body_ok: problems.append(f"brainrot {name}: bad body")
    if not eyes or eyes.group(1) not in eyes_ok: problems.append(f"brainrot {name}: bad eyes")
    if not mouth or mouth.group(1) not in mouth_ok: problems.append(f"brainrot {name}: bad mouth")
    # No closing brace: `look` is captured up to the entry's `} } }`, so extras (always last) lose theirs.
    ex = re.search(r"extras = \{([^}]*)", look)
    for e in re.findall(r'"(\w+)"', ex.group(1) if ex else ""):
        if e not in extras_ok: problems.append(f"brainrot {name}: unknown extra {e}")
dupes = {n for n in names if names.count(n) > 1}
if dupes: problems.append(f"duplicate brainrot names: {dupes}")
per = {r: 0 for r in RARITIES}
for m in re.finditer(r'rarity = "(\w+)", coinValue', data):
    per[m.group(1)] = per.get(m.group(1), 0) + 1
print("brainrots:", len(names), per)
for r in RARITIES:
    if per.get(r, 0) == 0: problems.append(f"no brainrots of rarity {r}")

# --- Crates / cosmetics ---------------------------------------------------------
crates = read("ReplicatedStorage/Shared/CrateData.lua")
for odds in re.findall(r"odds = \{([^}]*)\}", crates):
    for key in re.findall(r"(\w+) =", odds):
        if key not in RARITIES: problems.append(f"crate odds bad rarity {key}")
order = re.findall(r'"(\w+)"', re.search(r"CrateData\.Order = \{([^}]*)\}", crates).group(1))
defined = re.findall(r"^\t(\w+) = \{", crates, re.M)
if set(order) != set(defined): problems.append(f"CrateData order {order} vs defined {defined}")
pd = read("ServerScriptService/Modules/PlayerData.lua")
crate_defaults = re.search(r"Crates = \{(.*?)\},", pd, re.S).group(1)
for key in order:
    if not re.search(rf"\b{key} = 0", crate_defaults): problems.append(f"PlayerData Crates default missing {key}")
cos = read("ReplicatedStorage/Shared/CosmeticData.lua")
items_block = cos.split("CosmeticData.Items = {", 1)[1] if "CosmeticData.Items = {" in cos else cos
for m in re.finditer(r"^\t(\w+) = \{\n(.*?)^\t\},", items_block, re.S | re.M):
    item_id, body = m.groups()
    rar = re.search(r'rarity = "(\w+)"', body)
    if not rar: problems.append(f"cosmetic {item_id} has no rarity")
    elif rar.group(1) not in RARITIES: problems.append(f"cosmetic {item_id} bad rarity")
    if "crateOnly = true" not in body and "bundleOnly = true" not in body and "rankOnly = true" not in body and "price =" not in body: problems.append(f"cosmetic {item_id} has no price and isn't crateOnly/bundleOnly/rankOnly")
cosmetic_ids = set(re.findall(r"^\t(\w+) = \{\n", items_block, re.M))
gp = read("ReplicatedStorage/Shared/GamepassConfig.lua")
for cid in re.findall(r'kind = "Cosmetic", id = "(\w+)"', gp):
    if cid not in cosmetic_ids: problems.append(f"GamepassConfig bundle gives unknown cosmetic {cid}")
for crate_id in re.findall(r'crate = "(\w+)"', gp):
    if crate_id not in order: problems.append(f"GamepassConfig gives unknown crate {crate_id}")
for cons in re.findall(r'consumable = "(\w+)"', gp):
    if not re.search(rf"Consumables = \{{[^}}]*\b{cons} = 0", pd): problems.append(f"GamepassConfig gives unknown consumable {cons}")

# --- Brainrot merging and Legendary+ scarcity ------------------------------------
# Merging: the constants agree with each other, old saves get a Stars table, every stat readout
# passes stars, and the server remote, confirm dialog and menu are wired together. Scarcity: the
# Legendary-and-up odds retuned on 2026-09-16 are asserted as ceilings so a later edit can't
# quietly loosen them, and the README's tables and prose must state what the data says.
brd = read("ReplicatedStorage/Shared/BrainrotData.lua")
max_stars = re.search(r"BrainrotData\.MaxStars = (\d+)", brd)
per_star = re.search(r"BrainrotData\.BonusPerStar = ([\d.]+)", brd)
merge_copies = re.search(r"BrainrotData\.MergeCopies = \{([^}]*)\}", brd)
if not (max_stars and per_star and merge_copies):
    problems.append("BrainrotData: MaxStars / BonusPerStar / MergeCopies missing")
else:
    max_stars, per_star = int(max_stars.group(1)), float(per_star.group(1))
    copy_list = [c.strip() for c in merge_copies.group(1).split(",") if c.strip()]
    if len(copy_list) != max_stars: problems.append(f"MergeCopies has {len(copy_list)} entries but MaxStars is {max_stars}")
    if not all(c.isdigit() and int(c) > 0 for c in copy_list): problems.append(f"MergeCopies must be positive whole numbers: {copy_list}")
    if not 0 < per_star <= 0.5: problems.append(f"BonusPerStar {per_star} is outside (0, 0.5]")
    print(f"merging: {max_stars} stars, +{per_star:.0%} each, spares per star {', '.join(copy_list)}")
if "function BrainrotData.Stats(def, level, stars)" not in brd: problems.append("BrainrotData.Stats doesn't take stars")
if not re.search(r"^\t\tStars = \{\},", pd, re.M): problems.append("PlayerData's default profile has no Stars table")
if "saved.Stars" not in pd: problems.append("PlayerData reconcile never reads saved.Stars")
rs_src = read("ServerScriptService/Modules/RewardService.lua")
if "function RewardService.MergeBrainrot(player, name, fromStars)" not in rs_src: problems.append("RewardService.MergeBrainrot(player, name, fromStars) missing")
boot = read("ServerScriptService/Bootstrap.server.lua")
if not re.search(r'Remotes\.Function\("MergeBrainrot"\)\.OnServerInvoke = guard\(function\(player, name, fromStars\)', boot):
    problems.append("Bootstrap: MergeBrainrot remote isn't guarded or doesn't take fromStars")
if "RewardService.IsTrading = " not in boot: problems.append("Bootstrap never sets RewardService.IsTrading, so merges aren't refused mid-trade")
menu = read("StarterPlayerScripts/MenuClient.client.lua")
if 'require(script.Parent:WaitForChild("MergeDialog"))' not in menu or "MergeDialog.Open(" not in menu:
    problems.append("MenuClient doesn't open MergeDialog, so MERGE would skip its confirmation")
if not re.search(r"mergeBrainrot:InvokeServer\(entry\.name, stars\)", menu): problems.append("MenuClient's merge call doesn't send the star count it confirmed")
dialog_path = os.path.join("StarterPlayerScripts", "MergeDialog.lua")
if not os.path.exists(os.path.join(root, dialog_path)): problems.append("StarterPlayerScripts/MergeDialog.lua missing")
for sfx_name in set(re.findall(r'Sfx\.Play\("(\w+)"', menu)):
    if not re.search(rf"^\t{sfx_name} = \{{", read("ReplicatedStorage/Shared/SoundConfig.lua"), re.M): problems.append(f"MenuClient plays unknown sound {sfx_name}")
for rel in ("ServerScriptService/Modules/CompanionService.lua", "ServerScriptService/Modules/ShowcaseService.lua",
            "StarterPlayerScripts/HudClient.client.lua", "StarterPlayerScripts/MenuClient.client.lua", dialog_path):
    for call in re.findall(r"BrainrotData\.Stats\(([^)]*)\)", read(rel)):
        if call.count(",") < 2: problems.append(f"{rel}: BrainrotData.Stats({call}) ignores merge stars")

def weights(block):
    return {k: float(v) for k, v in re.findall(r"(\w+) = ([\d.]+)", block)}
def share_at_least(odds, floor):
    total = sum(odds.values())
    return 100 * sum(v for k, v in odds.items() if k in RARITIES and RARITIES.index(k) >= RARITIES.index(floor)) / total if total else 0
crate_defs = {}
for m in re.finditer(r"^\t(\w+) = \{\n(.*?)^\t\},", crates, re.S | re.M):
    tier, body = m.groups()
    odds = re.search(r"odds = \{([^}]*)\}", body)
    pity = re.search(r'pity = \{ every = (\d+), rarity = "(\w+)" \}', body)
    crate_defs[tier] = {"odds": weights(odds.group(1)) if odds else {}, "pity": (int(pity.group(1)), pity.group(2)) if pity else None,
                        "brainrot": 'category = "Brainrot"' in body}
for tier, crate in crate_defs.items():
    if abs(sum(crate["odds"].values()) - 100) > 1e-6: problems.append(f"crate {tier} odds add up to {sum(crate['odds'].values())}, not 100")
    if crate["pity"] and crate["pity"][1] not in crate["odds"]: problems.append(f"crate {tier} pity rarity {crate['pity'][1]} can't be rolled by its odds")
# Ceilings on Legendary and up (crate, floor rarity, most percent). Raise one only on purpose.
SCARCITY = [("Rare", "Legendary", 3), ("Epic", "Legendary", 14), ("Epic", "Mythic", 2), ("Legendary", "Legendary", 42),
            ("Legendary", "Mythic", 8), ("Legendary", "Secret", 1), ("Mythic", "Mythic", 20), ("Mythic", "Secret", 3), ("Super", "Secret", 10)]
for tier, floor, cap in SCARCITY:
    if tier not in crate_defs: problems.append(f"scarcity check: no {tier} crate"); continue
    got = share_at_least(crate_defs[tier]["odds"], floor)
    if got > cap + 1e-6: problems.append(f"{tier} Crate rolls {floor} or better {got:.1f}% of the time; the ceiling is {cap}%")
for tier, least in {"Epic": 25, "Legendary": 40, "Mythic": 50}.items():
    pity = crate_defs.get(tier, {}).get("pity")
    if not pity or pity[0] < least: problems.append(f"{tier} Crate pity {pity} guarantees sooner than {least} opens")
shop_src = read("ReplicatedStorage/Shared/ShopRotation.lua")
crate_chance = weights(re.search(r"ShopRotation\.CrateChance = \{(.*?)\n\}", shop_src, re.S).group(1))
for tier, cap in (("Legendary", 0.25), ("Mythic", 0.10)):
    if crate_chance.get(tier, 1) > cap + 1e-9: problems.append(f"ShopRotation: {tier} Crate is in stock {crate_chance.get(tier)} of rotations; the ceiling is {cap}")
spin_src = read("ReplicatedStorage/Shared/DailySpinData.lua")
spin_brainrot = re.search(r'kind = "Brainrot".*?rarities = \{([^}]*)\}', spin_src, re.S)
if not spin_brainrot: problems.append("DailySpinData has no Brainrot segment rarities")
elif share_at_least(weights(spin_brainrot.group(1)), "Legendary") > 5 + 1e-6: problems.append("Daily Spin's brainrot prize is Legendary more than 5% of the time")

readme = read("README.md")
flat_readme = re.sub(r"\s+", " ", readme)
rarity_pct = r"\b(" + "|".join(RARITIES) + r") ([\d.]+)%"
for tier, crate in crate_defs.items():
    if not crate["brainrot"]: continue
    # Several README tables start a row with a rarity name; the crate table's third column is odds.
    rows = [r.group(1) for r in re.finditer(rf"^\| (?:\*\*)?{tier}(?:\*\*)? \|[^|\n]*\|([^|\n]*)\|", readme, re.M)
            if re.search(rarity_pct, r.group(1).replace("*", ""))]
    if len(rows) != 1: problems.append(f"README: expected one crate table row for {tier}, found {len(rows)}"); continue
    stated = {k: float(v) for k, v in re.findall(rarity_pct, rows[0].replace("*", ""))}
    if stated != crate["odds"]: problems.append(f"README's {tier} Crate row says {stated}, CrateData says {crate['odds']}")
for tier, text in (("Epic", "Epic: Legendary+ within {}"), ("Legendary", "Legendary: Mythic+ within {}"), ("Mythic", "Mythic: Secret within {}")):
    pity = crate_defs.get(tier, {}).get("pity")
    if pity and text.format(pity[0]) not in flat_readme: problems.append(f"README's pity text for the {tier} Crate doesn't say {pity[0]}")
stock = re.search(r"Legendary (\d+)% and Mythic just (\d+)%", flat_readme)
if not stock or (int(stock.group(1)), int(stock.group(2))) != (round(crate_chance.get("Legendary", 0) * 100), round(crate_chance.get("Mythic", 0) * 100)):
    problems.append("README's crate stock sentence doesn't match ShopRotation.CrateChance")
if spin_brainrot:
    spin_row = re.search(r"^\| BRAINROT \|.*$", readme, re.M)
    stated = {k: float(v) for k, v in re.findall(r"(\w+) \(([\d.]+)%\)", spin_row.group(0).replace("*", ""))} if spin_row else {}
    if stated != weights(spin_brainrot.group(1)): problems.append(f"README's Daily Spin BRAINROT row says {stated}, DailySpinData says {weights(spin_brainrot.group(1))}")
if max_stars and f"up to five stars (+{round(max_stars * per_star * 100)}%)" not in flat_readme:
    problems.append("README's merging text doesn't state the five-star bonus BrainrotData gives")

# --- Buildings live only in MapBuildings -----------------------------------------
# Building code was moved out of MapGenerator and MapDecor on 2026-09-16 (a fixed-seed build of three
# whole maps was identical before and after) so the buildings and the town/road layout can be owned
# by different sessions. A stale copy of MapGenerator or MapDecor pasted back over the real one would
# quietly bring the old building code back, and fixes made in MapBuildings would stop running with
# no error anywhere. This catches that.
_gen = read("ServerScriptService/Modules/MapGenerator.lua")
_decor = read("ServerScriptService/Modules/MapDecor.lua")
if not os.path.exists(os.path.join(root, "ServerScriptService", "Modules", "MapBuildings.lua")):
    problems.append("ServerScriptService/Modules/MapBuildings.lua is missing")
else:
    _mb = read("ServerScriptService/Modules/MapBuildings.lua")
    for _name in ("RollPlan", "BuildBuilding", "BuildCrate"):
        if not re.search(rf"^MapBuildings\.{_name} = ", _mb, re.M):
            problems.append(f"MapBuildings.lua no longer exports {_name}, which MapGenerator's towns call")
if 'require(script.Parent:WaitForChild("MapBuildings"))' not in _gen:
    problems.append("MapGenerator.lua no longer requires MapBuildings")
# freeSpot / trimFor / dressGround are deliberately NOT in this list: they are generic enough that a
# road or terrain change could legitimately define one in MapGenerator, and the building-specific
# names plus the constants below already catch a stale copy pasted back.
for _fn in re.findall(r"^local function (buildWall|buildStairs|buildFloorWithWell|buildPitchedRoof|buildFlatRoof|buildInterior|dressWall|addBalcony|addLoadingDock|rollPlan|buildBuilding|buildCrate)\(", _gen, re.M):
    problems.append(f"MapGenerator.lua defines {_fn} again; building code lives in MapBuildings.lua (a stale copy pasted back?)")
for _const in re.findall(r"^local (FLOOR_HEIGHT|WALL_THICKNESS|SILL_HEIGHT|WINDOW_TOP|WINDOW_WIDTH|DOOR_WIDTH|STAIR_WIDTH|STAIR_RUN|STAIR_STEPS|STAIR_LANDING) =", _gen, re.M):
    problems.append(f"MapGenerator.lua defines {_const} again; building constants live in MapBuildings.lua")
if re.search(r"^function MapDecor\.Building\(", _decor, re.M) or re.search(r"^local function (acUnit|waterTank|antenna)\(", _decor, re.M):
    problems.append("MapDecor.lua defines building decor again (MapDecor.Building/acUnit/waterTank/antenna); it lives in MapBuildings.lua (a stale copy pasted back?)")

# --- Passes, crate luck, coin earning and the brainrot shop ----------------------
# Paid random items must show the odds a player really gets, the 2x SahurCoins pass must reach every
# earned coin, the pair of passes must not turn crates into a coin printer, and a Robux brainrot
# purchase must grant exactly the brainrot picked. These pin all of that down.
gp_passes = gp.split("GamepassConfig.Products = {", 1)[0]
def pass_block(key):
    m = re.search(rf"^\t{key} = \{{\n(.*?)^\t\}},", gp_passes, re.S | re.M)
    return m.group(1) if m else ""
coin_pass, luck_pass = pass_block("CoinBoost"), pass_block("CrateLuck")
if "suggestedPrice = 350" not in coin_pass: problems.append("GamepassConfig: 2x SahurCoins (CoinBoost) isn't listed at 350 R$")
if not luck_pass: problems.append("GamepassConfig: no CrateLuck pass")
else:
    if "suggestedPrice = 350" not in luck_pass: problems.append("GamepassConfig: 2x Crate Luck isn't listed at 350 R$")
    if "luck = 2" not in luck_pass: problems.append("GamepassConfig: CrateLuck.luck isn't 2")
coin_mult = float(re.search(r"multiplier = ([\d.]+)", coin_pass).group(1)) if re.search(r"multiplier = ([\d.]+)", coin_pass) else 2.0
doubles_selling = "doublesSelling = true" in coin_pass
pass_luck = int(re.search(r"luck = (\d+)", luck_pass).group(1)) if re.search(r"luck = (\d+)", luck_pass) else 2
prices = {k: int(v) for k, v in re.findall(r"(\w+) = (\d+)", re.search(r"GamepassConfig\.BrainrotPrices = \{(.*?)\}", gp, re.S).group(1))} if "GamepassConfig.BrainrotPrices" in gp else {}
product_ids = re.search(r"GamepassConfig\.BrainrotProductIds = \{(.*?)\}", gp, re.S)
if set(prices) != set(RARITIES): problems.append(f"GamepassConfig.BrainrotPrices must price every rarity exactly once: {sorted(prices)}")
elif prices["Secret"] != 2000: problems.append(f"Secret brainrots must cost 2000 R$, not {prices['Secret']}")
elif any(prices[RARITIES[i]] >= prices[RARITIES[i + 1]] for i in range(len(RARITIES) - 1)): problems.append(f"brainrot prices must rise strictly with rarity: {prices}")
if not product_ids or set(re.findall(r"(\w+) = \d+", product_ids.group(1))) != set(RARITIES): problems.append("GamepassConfig.BrainrotProductIds must list every rarity")

# The luck transform, re-derived here from its definition (best of L rolls), for every crate.
def effective_odds(odds, luck):
    total = sum(odds.values())
    out, at_least, above = {}, 0.0, 0.0
    for r in reversed(RARITIES):
        if odds.get(r, 0) > 0:
            at_least = min(1.0, at_least + odds[r] / total)
            boosted = 1 - (1 - at_least) ** luck
            out[r] = (boosted - above) * 100
            above = boosted
    return out
if "function CrateData.EffectiveOdds(crate, luck)" not in crates: problems.append("CrateData.EffectiveOdds(crate, luck) missing")
for tier, crate in crate_defs.items():
    for luck in (1, 2, 4):
        eff = effective_odds(crate["odds"], luck)
        if abs(sum(eff.values()) - 100) > 1e-9 or min(eff.values()) < -1e-12 or set(eff) != set(crate["odds"]):
            problems.append(f"{tier} Crate luck x{luck} odds are broken: {eff}")
    base, lucky = effective_odds(crate["odds"], 1), effective_odds(crate["odds"], 2)
    if any(abs(base[r] - crate["odds"][r] / sum(crate["odds"].values()) * 100) > 1e-9 for r in base): problems.append(f"{tier} Crate luck x1 differs from its own odds")
    top = [r for r in reversed(RARITIES) if r in base][0] if base else None
    if top and len(base) > 1 and not lucky[top] > base[top]: problems.append(f"{tier} Crate: luck doesn't raise its rarest tier")
# Shown odds must be rolled odds: the roll, the snapshot and the crate cards all use the same luck and function.
crate_service = read("ServerScriptService/Modules/CrateService.lua")
state_sync = read("ServerScriptService/Modules/StateSync.lua")
if "local luck = CrateData.LuckFor(crate, Monetization.CrateLuck(player), boosted)" not in crate_service or "Rarity.Roll(CrateData.EffectiveOdds(crate, luck))" not in crate_service:
    problems.append("CrateService.Open doesn't roll with CrateData.EffectiveOdds at CrateData.LuckFor(pass luck, Beginner's Luck)")
if re.search(r"Rarity\.Roll\(\s*crate\.odds\s*\)", crate_service): problems.append("CrateService rolls raw crate.odds somewhere, bypassing crate luck")
if "crateLuck = Monetization.CrateLuck(player)" not in state_sync: problems.append("StateSync doesn't send crateLuck from Monetization.CrateLuck")
if "local luck = profile and profile.crateLuck or 1" not in menu or "CrateData.OddsLine(crate, luck, boosted)" not in menu:
    problems.append("MenuClient's crate cards don't build their odds line with CrateData.OddsLine at the player's crateLuck")
# The one place the odds line is built, so a card can never print a number the roll didn't use.
_odds_line = re.search(r"function CrateData\.OddsLine\(crate, luck, boosted\)(.*?)\nend\n", crates, re.S)
# The full rarity word since #86 ("Unco" / "Lege" were not words a player knows); the rule is that
# a boosted crate prints the NAME alone, with no percentage beside it.
if not _odds_line or not re.search(r"boosted and rarity\s*\n", _odds_line.group(1)):
    problems.append("CrateData.OddsLine must print rarity names only for a boosted crate")
for use in re.findall(r"crate\.odds\[[^\]]+\][^\n]*", menu):
    if "> 0" not in use: problems.append(f"MenuClient reads raw crate.odds for something other than 'can this rarity drop': {use.strip()}")

# The README's luck table must state what EffectiveOdds gives (it's what players are told).
flat_readme_luck = read("README.md")
luck_pair = r"\b(" + "|".join(RARITIES) + r") ([\d.]+)\b"
for tier, crate in crate_defs.items():
    # Other README tables also start rows with a rarity name; the luck table's two columns are both odds.
    rows = [r for r in re.finditer(rf"^\| {tier} \| ([^|\n]*) \| ([^|\n]*) \|$", flat_readme_luck, re.M)
            if re.search(luck_pair, r.group(1)) and re.search(luck_pair, r.group(2)) and "%" not in r.group(0)]
    row = rows[0] if rows else None
    if crate["brainrot"] and row:
        stated = {k: float(v) for k, v in re.findall(luck_pair, row.group(2))}
        want = {r: round(p, 2) for r, p in effective_odds(crate["odds"], pass_luck).items()}
        if stated != want: problems.append(f"README's 2x Crate Luck row for {tier} says {stated}, EffectiveOdds gives {want}")
    elif crate["brainrot"] and "2x Crate Luck" in flat_readme_luck:
        problems.append(f"README's 2x Crate Luck table has no row for the {tier} Crate")

# No coin printer: for an owner of every pass, a coin-priced brainrot crate must return less on average
# (pulls sold, at the best luck and sell multiplier any pass gives, plus jackpots) than it costs.
sell_values = {}
for m in re.finditer(r'rarity = "(\w+)", coinValue = (\d+)', data):
    sell_values.setdefault(m.group(1), []).append(int(m.group(2)))
avg_sell = {r: sum(v) / len(v) for r, v in sell_values.items()}
sell_mult = coin_mult if doubles_selling else 1.0
for m in re.finditer(r"^\t(\w+) = \{\n(.*?)^\t\},", crates, re.S | re.M):
    tier, body = m.groups()
    price = re.search(r"coinPrice = (\d+)", body)
    if tier not in crate_defs or not crate_defs[tier]["brainrot"] or not price: continue
    jackpot = re.search(r"jackpot = \{ chance = ([\d.]+), min = (\d+), max = (\d+)", body)
    jackpot_ev = float(jackpot.group(1)) * (int(jackpot.group(2)) + int(jackpot.group(3))) / 2 if jackpot else 0
    eff = effective_odds(crate_defs[tier]["odds"], pass_luck)
    ev = sum(eff[r] / 100 * avg_sell.get(r, 0) for r in eff) * sell_mult + jackpot_ev
    if ev >= int(price.group(1)): problems.append(f"{tier} Crate is a coin printer for pass owners: returns {ev:.0f} on average for {price.group(1)} (luck x{pass_luck}, selling x{sell_mult:g})")

# Every earned coin goes through Monetization.EarnCoins; only Robux grants, crate refunds and jackpots
# and EarnCoins itself may add coins directly.
ALLOWED_DIRECT = {"Bootstrap.server.lua": 3, "CrateService.lua": 2, "Monetization.lua": 1}
for rel, text in lua_files():
    if not rel.startswith("ServerScriptService"): continue
    n = len(re.findall(r"SahurCoins\s*\+=", re.sub(r"--[^\n]*", "", text)))
    allowed = ALLOWED_DIRECT.get(os.path.basename(rel), 0)
    if n > allowed: problems.append(f"{rel} adds SahurCoins directly {n} times (allowed {allowed}); pay earned coins through Monetization.EarnCoins so the 2x pass applies")
reward_src = read("ServerScriptService/Modules/RewardService.lua")
if len(re.findall(r'RewardService\.AddCoins\([^)]*"sell"\)', reward_src)) != 3: problems.append("RewardService: the three sell paths must pay through AddCoins(..., \"sell\")")
monet = read("ServerScriptService/Modules/Monetization.lua")
if "function Monetization.EarnCoins(player, amount, source)" not in monet: problems.append("Monetization.EarnCoins missing")
receipt = re.search(r"function Monetization\.HandleReceipt\(player, receiptInfo\)(.*?)\nend\n", monet, re.S)
if not receipt: problems.append("Monetization.HandleReceipt missing")
else:
    body = receipt.group(1)
    grant_at = body.find("pcall(handler")
    order_ok = -1 < body.find("alreadyGranted(data, purchaseId)") < grant_at < body.find("recordPurchase(data, purchaseId)") < body.find("PlayerData.SaveAndWait(player)", grant_at)
    if not order_ok: problems.append("HandleReceipt must check PurchaseId, then grant, then record it, then save, in that order")
    # Review 2026-09-17: a receipt is confirmed only after a successful save, including one granted
    # earlier in the session (its save may have failed), and nothing goes into a profile that can't save.
    dup = re.search(r"if alreadyGranted\(data, purchaseId\) then(.*?)\n\tend\n", body, re.S)
    if not dup or "if not PlayerData.SaveAndWait(player) and not studioTestGrant then" not in dup.group(1): problems.append("HandleReceipt confirms an already-granted receipt without saving it first")
    if "PlayerData.CanSave(player)" not in body[:max(0, body.find("alreadyGranted"))]: problems.append("HandleReceipt must refuse (NotProcessedYet) before granting into a profile that can't save")
    if "return (saved or studioTestGrant) and Enum.ProductPurchaseDecision.PurchaseGranted or notYet" not in body: problems.append("HandleReceipt must only return PurchaseGranted after its save succeeded (or a Studio test grant)")
    # The Studio test-grant exception must need BOTH halves, so it can never be true in a live server.
    if "local studioTestGrant = STUDIO_TEST_GRANTS and not PlayerData.HasStore()" not in body: problems.append("Monetization: the Studio test-grant exception must be RunService:IsStudio() AND no DataStore")
    if "local STUDIO_TEST_GRANTS = RunService:IsStudio()" not in monet: problems.append("Monetization: STUDIO_TEST_GRANTS must come from RunService:IsStudio()")
    if "pcall(result)" not in body[body.find("PlayerData.SaveAndWait(player)", grant_at):]: problems.append("HandleReceipt must run a handler's announce after recording and saving, in its own pcall")
# Grant handlers change the profile only; toasts, pushes, reveals and collection checks go in the
# announce function they return, which runs after the save (an error there must never re-grant).
for m in re.finditer(r'Monetization\.RegisterGrantHandler\("(\w+)", function\(.*?\n(.*?)\nend\)\n', boot, re.S):
    kind, handler_body = m.groups()
    grant_part = handler_body.split("return function()")[0]
    if "return function()" not in handler_body: problems.append(f"Bootstrap: the {kind} grant handler returns no announce function")
    for call in ("StateSync.Notify", "StateSync.Push", ":FireClient", "CheckCollections"):
        if call in re.sub(r"--[^\n]*", "", grant_part): problems.append(f"Bootstrap: the {kind} grant handler calls {call} before its announce; a failure there would re-grant on retry")
if re.search(r"Monetization\.Clear\(", re.sub(r"--[^\n]*", "", read("ServerScriptService/Modules/BattlePassService.lua"))):
    problems.append("BattlePassService calls Monetization.Clear, which switches off the player's paid passes until they rejoin")
if "MarketplaceService.PromptGamePassPurchaseFinished:Connect(Monetization.OnPassPurchaseFinished)" not in monet: problems.append("Monetization: pass purchases must go through OnPassPurchaseFinished (marks the pass owned despite Roblox's cached ownership check)")
if "SafeValue.Number(shownLuck, 100) and shownLuck or nil" not in boot or "invoke(openCrate, tier, not boosted and luck or nil)" not in menu or "shownLuck ~= nil and shownLuck ~= luck" not in crate_service:
    problems.append("Crate opens must carry the luck the card showed (SafeValue-checked) and CrateService.Open must refuse a mismatch")
# Beginner's Luck: hidden, free crates only, a fixed number of charges that nothing can refill.
_bl_crates = read("ReplicatedStorage/Shared/CrateData.lua")
_bl_count = re.search(r"CrateData\.BeginnerCrates = (\d+)", _bl_crates)
if not _bl_count or not re.search(r"CrateData\.BeginnerLuck = (\d+)", _bl_crates): problems.append("CrateData: Beginner's Luck constants missing")
elif int(_bl_count.group(1)) > 10: problems.append("CrateData.BeginnerCrates is more than 10; it's meant to be a handful of opens")
# Nothing may ever raise the charge count outside the one-off grant in PlayerData/ProgressionData.
for _bl_rel, _bl_text in lua_files():
    # PlayerData/ProgressionData own the one-off grant; CrateData owns the rule; probes only assert.
    if _bl_rel.endswith(("PlayerData.lua", "ProgressionData.lua", "CrateData.lua")) or os.path.basename(os.path.dirname(_bl_rel)) == "tools": continue
    for _bl_write in re.findall(r"beginnerLuck[^\n]*", re.sub(r"--[^\n]*", "", _bl_text)):
        # An assignment, not a comparison: `= x` or `+= x`, never `==`.
        if re.search(r"beginnerLuck\.left\s*(\+=|=[^=])", _bl_write) and "-= 1" not in _bl_write:
            problems.append(f"{_bl_rel}: writes Beginner's Luck charges ({_bl_write.strip()}); only the one-off grant may, and opens may only spend one")
# The one-off grant: charges and the marker set together, behind the marker, nowhere else.
_bl_grant = re.search(r"function CrateService\.GrantBeginnerLuck\(player\)(.*?)\nend\n", crate_service, re.S)
if not _bl_grant: problems.append("CrateService.GrantBeginnerLuck missing (the one-off Beginner's Luck grant)")
else:
    _bl_body = _bl_grant.group(1)
    if "if beginner.granted == true then" not in _bl_body or _bl_body.find("beginner.granted == true") > _bl_body.find("beginner.left = CrateData.BeginnerCrates"):
        problems.append("GrantBeginnerLuck must refuse on the granted marker BEFORE handing out charges")
    if "beginner.granted = true" not in _bl_body: problems.append("GrantBeginnerLuck must set the granted marker with the charges, so it can never grant twice")
if "CrateService.GrantBeginnerLuck(player)" not in boot: problems.append("Bootstrap never runs the one-off Beginner's Luck grant on profile load")
if len(re.findall(r"beginner\.left = ", crate_service)) != 1: problems.append("CrateService sets Beginner's Luck charges somewhere other than the one-off grant")
if "if boosted then\n\t\tdata.Progression.beginnerLuck.left -= 1" not in crate_service: problems.append("CrateService.Open must spend exactly one Beginner's Luck charge on a boosted open")
if "CrateData.BeginnerBoosted(CrateData.Get(tier), data.Crates[tier], data.PaidCrates[tier]" not in crate_service: problems.append("CrateService must decide the boost with CrateData.BeginnerBoosted (a tier holding any bought crate is never boosted)")
# A boosted card hides its percentages, so it must be impossible to hold a bought crate of that tier:
# the rule takes the whole holding, and bought crates (Robux and coin) open before free ones.
if "local bought = paid + math.max(0, held - paid - free)" not in _bl_crates: problems.append("CrateData.BeginnerBoosted must count coin-bought crates as bought (coins are bought with Robux)")
if "elseif coinBought <= 0 and free > 0 then" not in crate_service: problems.append("CrateService.Open must spend Robux crates, then coin-bought ones, then free ones")
if "crateBoosted = crateBoosted(data)" not in state_sync: problems.append("StateSync must send which crate tiers are boosted, so the menu can draw them without odds")
if "local boosted = profile and profile.crateBoosted and profile.crateBoosted[tier] or false" not in menu:
    problems.append("MenuClient must ask the server which crates are boosted (crateBoosted) before drawing their odds")

# Cosmetic crate tiers (the Style ladder). Each is sold two ways, so each needs BOTH routes wired:
# a coin price and a developer product that exists in GamepassConfig -- a tier with only one of them
# renders a button that can't be pressed.
_style_tiers = re.findall(r'\n\t(\w+) = \{\n\t\tname = "[^"]+",\n\t\tcategory = "Cosmetic",(.*?)\n\t\},', _bl_crates, re.S)
if len(_style_tiers) < 3:
    problems.append("CrateData: expected three Cosmetic crate tiers (Style, DeluxeStyle, PrestigeStyle)")
for _tier, _body in _style_tiers:
    if "coinPrice" not in _body:
        problems.append("CrateData.%s: a cosmetic crate tier with no coin price" % _tier)
    if "kinds = {" not in _body:
        problems.append("CrateData.%s: a Style tier must name the cosmetic kinds it draws from" % _tier)
    _key = re.search(r'productKey = "(\w+)"', _body)
    if not _key:
        problems.append("CrateData.%s: no productKey, so it can't be bought with Robux" % _tier)
    elif not re.search(r'\n\t' + _key.group(1) + r' = \{', gp):
        problems.append("CrateData.%s: productKey %s isn't in GamepassConfig.Products" % (_tier, _key.group(1)))

# The crate open. One curve, in Shared/CrateOpen, played by the reveal and rendered frame by frame by
# tools/crate_card_gallery.lua -- a second copy of it in MenuClient is how a render stops being
# evidence about the animation people actually see.
_open_src = read("ReplicatedStorage/Shared/CrateOpen.lua")
if "function CrateOpen.LidCFrame" not in _open_src or "function CrateOpen.Angle" not in _open_src:
    problems.append("Shared/CrateOpen: the lid swing (Angle, LidCFrame) is missing")
if "CrateOpen.LidCFrame(lidStart, lidHinge" not in menu:
    problems.append("MenuClient's crate reveal must swing the lid through CrateOpen.LidCFrame, not its own CFrame maths")
_reveal = re.search(r"-- The crate OPENS:(.*?)local fade = ", menu, re.S)
if _reveal and "CFrame.Angles" in _reveal.group(1):
    problems.append("MenuClient's crate reveal computes its own lid rotation; the swing belongs to Shared/CrateOpen")

# The codex: one entry per brainrot, keyed by name, inside the length the panel can show.
#
# Nothing draws it yet -- wiring waits on Oliver's sort answer -- but the DATA can be wrong now and
# only discovered the day it is wired, so it is checked now. An entry keyed to a brainrot that does
# not exist is invisible until someone opens that page and finds nothing.
_codex_src = read("ReplicatedStorage/Shared/BrainrotCodex.lua")
_codex_names = set(re.findall(r'\n\t\["([^"]+)"\] = "', _codex_src))
_type_names = set(re.findall(r'\{ name = "([^"]+)", rarity = ', read("ReplicatedStorage/Shared/BrainrotData.lua")))
if not _type_names:
    problems.append("BrainrotData: no brainrot names matched; the codex check cannot run")
else:
    _orphans = sorted(_codex_names - _type_names)
    if _orphans:
        problems.append("BrainrotCodex has entries for brainrots that don't exist: " + ", ".join(_orphans[:5]))
    _missing = sorted(_type_names - _codex_names)
    if _missing:
        problems.append("BrainrotCodex is missing %d of %d brainrots (e.g. %s)"
                        % (len(_missing), len(_type_names), ", ".join(_missing[:3])))
    _limit_m = re.search(r"BrainrotCodex\.MaxLength = (\d+)", _codex_src)
    _limit = int(_limit_m.group(1)) if _limit_m else 0
    if _limit <= 0:
        problems.append("BrainrotCodex.MaxLength is missing, so nothing bounds the entries")
    else:
        _longest, _longest_name = 0, ""
        for _name, _text in re.findall(r'\n\t\["([^"]+)"\] = "([^"]*)"', _codex_src):
            if len(_text) > _longest:
                _longest, _longest_name = len(_text), _name
            if len(_text) > _limit:
                problems.append("BrainrotCodex entry for %s is %d characters, over MaxLength %d"
                                % (_name, len(_text), _limit))
            # The file's own house rules, the two a checker can actually judge.
            if "!" in _text:
                problems.append("BrainrotCodex entry for %s has an exclamation mark; the house voice has none" % _name)
            if _name.split(" ")[0] in _text:
                problems.append("BrainrotCodex entry for %s says its own name; the row above already shows it" % _name)
        print("codex: %d entries, longest %d/%d chars (%s)" % (len(_codex_names), _longest, _limit, _longest_name))

# The defense cap is one number, and the player can read it.
#
# It used to be a literal in DefenseService that nothing told the player about: a fourth wall
# silently collapsed their oldest. The number now lives in ItemData, the three structures' own
# descriptions are composed from it, and DefenseService reads it from there. Each half of that is
# checked, because either half alone puts the game back where it was -- a number nobody sees, or a
# sentence that can drift from what the server does.
_item_src = read("ReplicatedStorage/Shared/ItemData.lua")
_def_src = read("ServerScriptService/Modules/DefenseService.lua")
if not re.search(r"ItemData\.MaxStructuresPerPlayer = (\d+)", _item_src):
    problems.append("ItemData.MaxStructuresPerPlayer is gone; the defense cap has no shared source")
else:
    if "local MAX_PER_PLAYER = ItemData.MaxStructuresPerPlayer" not in _def_src:
        problems.append("DefenseService: MAX_PER_PLAYER must come from ItemData.MaxStructuresPerPlayer, not a second literal")
    # The sentence has to be composed from the constant, never typed out: a digit in the prose is a
    # copy that nothing keeps in step with the server.
    # `capRule` is a field of its own, not a sentence glued onto `description`: joining two fields
    # is a line of code, while splitting one requires parsing English. And it is COMPOSED from the
    # constant -- a split is exactly the moment someone types "three" by hand.
    _rule = _item_src.split('].capRule = string.format(')
    if len(_rule) < 2 or 'MaxStructuresPerPlayer' not in _rule[-1][:300]:
        problems.append("ItemData: the structures' capRule must be composed from MaxStructuresPerPlayer")
    elif re.search(r'\b(one|two|three|four|\d+)\b of your own can stand', _item_src):
        problems.append("ItemData: the cap number is typed into capRule instead of composed from the constant")
    for _id in ("RotBarricade", "PopupBunker", "BrainrotFortress"):
        if _id not in _item_src.split("for _, id in ipairs({")[-1][:200]:
            problems.append("ItemData: %s no longer gets the cap sentence" % _id)
    # And the player has to be told when it fires, or the cap is still a surprise in the moment.
    if "StateSync.Notify" not in _def_src.split("while #mine >= MAX_PER_PLAYER do")[-1][:600]:
        problems.append("DefenseService: nothing tells the player when the cap collapses their oldest defense")

# The brainrot shop.
if 'Monetization.RegisterGrantHandler("Brainrot"' not in boot or "BrainrotShopService.Grant(" not in boot: problems.append("Bootstrap doesn't handle Brainrot receipts through BrainrotShopService.Grant")
if 'Remotes.Function("BuyBrainrot").OnServerInvoke = guard(' not in boot: problems.append("Bootstrap: BuyBrainrot remote missing or unguarded")
if "not product.brainrotShop" not in menu: problems.append("MenuClient lists brainrot products as plain shop rows, which would sell one without a pick")
if not re.search(r"^\t\tPendingBrainrot = \{\},", pd, re.M) or "saved.PendingBrainrot" not in pd: problems.append("PlayerData: PendingBrainrot default or reconcile missing")
shop_src = read("ServerScriptService/Modules/BrainrotShopService.lua")
if shop_src.find("data.PendingBrainrot[def.rarity] = {") > shop_src.find("pcall(BrainrotShopService.Prompt"): problems.append("BrainrotShopService must store the pick before opening the prompt")

# --- Client vectors must be checked component by component ----------------------
# NaN compares false against everything, so a type check plus `math.abs(v.X) > 1e6` or
# `v.Magnitude > 1e6` lets NaN in Y or Z straight through, and infinity becomes NaN at the first .Unit.
# A NaN aim once reached a server-owned body's velocity and every client's tracer. So a server file
# that type-checks a Vector3 with `~=` (the shape of a remote-argument guard) must use
# SafeValue.Vector3, and a file that handles OnServerEvent may not test a Vector3 by type alone.
for rel, text in lua_files():
    if not rel.startswith("ServerScriptService"):
        continue
    raw = re.findall(r'typeof\(\s*[\w.]+\s*\)\s*[~=]=\s*"Vector3"', re.sub(r"--[^\n]*", "", text))
    if raw and "SafeValue.Vector3" not in text and ("OnServerEvent" in text or any("~=" in g for g in raw)):
        problems.append(f"{rel}: checks a Vector3 by type alone ({raw[0]}); use SafeValue.Vector3, which also rejects NaN/inf in every component")
    for line_no, line in enumerate(text.split("\n"), 1):
        stripped = re.sub(r"--.*", "", line)
        if re.search(r'typeof\(\s*[\w.]+\s*\)\s*~=\s*"Vector3"', stripped):
            problems.append(f"{rel}:{line_no}: `typeof(...) ~= \"Vector3\"` guard; use `not SafeValue.Vector3(...)` instead")
if not os.path.exists(os.path.join(root, "ReplicatedStorage", "Shared", "SafeValue.lua")):
    problems.append("ReplicatedStorage/Shared/SafeValue.lua missing")

# --- Remotes: client names must exist on the server ------------------------------
server, client = set(), set()
for rel, text in lua_files():
    found = set(re.findall(r'Remotes\.(?:Event|Function)\("(\w+)"\)', text))
    (client if rel.startswith("StarterPlayerScripts") else server).update(found)
missing = client - server
if missing: problems.append(f"client-only remotes (never created/handled on server): {sorted(missing)}")

# --- Require cycles among server modules -------------------------------------
mods = {}
for rel, text in lua_files():
    if rel.startswith(os.path.join("ServerScriptService", "Modules")):
        mods[os.path.basename(rel)[:-4]] = set(re.findall(r'require\(script\.Parent:WaitForChild\("(\w+)"\)\)', text))
def cycle(node, stack, seen):
    for dep in mods.get(node, ()):
        if dep in stack: return stack[stack.index(dep):] + [dep]
        if dep not in seen:
            seen.add(dep); c = cycle(dep, stack + [dep], seen)
            if c: return c
for mod in mods:
    c = cycle(mod, [mod], {mod})
    if c: problems.append("require cycle: " + " -> ".join(c)); break

# --- Locals used above their definition (top-level `local function` only) -------
for rel, text in lua_files():
    lines = text.split("\n")
    defs = {}
    forward = set(re.findall(r"^local (\w+)\s*$", text, re.M)) | set(re.findall(r"^local ([\w, ]+)$", text, re.M))
    fwd = set()
    for f in forward: fwd.update(x.strip() for x in f.split(","))
    for i, line in enumerate(lines):
        m = re.match(r"^local function (\w+)", line)
        if m and m.group(1) not in defs: defs[m.group(1)] = i
    for name, at in defs.items():
        if name in fwd: continue
        for i in range(at):
            l = re.sub(r"--.*", "", lines[i])
            if re.search(rf"(?<![\w.:]){name}\s*\(", l):
                problems.append(f"{rel}:{i+1} uses {name} before its definition at line {at+1}")
                break

# --- Cloud Climb course ------------------------------------------------------------
# The obby's layout is generated and checked by tools/climb_design.py (every jump inside measured
# reach, nothing skippable, nothing clipping, rotors clear). Re-running it in check mode catches a
# hand edit to CloudClimbCourse.lua, a CANOPY change in LobbyService that the course was never
# re-checked against, and a design edit whose output was never regenerated.
import subprocess
_climb = subprocess.run([sys.executable, os.path.join(root, "tools", "climb_design.py"), root, "--check"],
                        capture_output=True, text=True)
if _climb.returncode != 0:
    for line in _climb.stdout.splitlines() + _climb.stderr.splitlines():
        if line.startswith("PROBLEM") or "Error" in line or "couldn't" in line:
            problems.append("climb_design: " + line)
    if not any(p.startswith("climb_design") for p in problems):
        problems.append("climb_design.py --check failed (exit %d)" % _climb.returncode)
else:
    print("cloud climb: " + next((l for l in _climb.stdout.splitlines() if "elements" in l), "checked"))

# --- Guns: models, animation, effects and sound agree -------------------------------
# GunModels builds every gun, Viewmodel animates it, GunFx draws its flash and tracer, and SoundConfig
# voices it, all joined by strings. Nothing but a playtest would otherwise notice a style with no
# builder, a Flash kind GunFx doesn't define (it quietly draws a rifle's), a tracer kind it doesn't know,
# or a cue SoundConfig doesn't have (silence). The per-gun geometry (sights on their line, nothing in
# the way, the ADS contract) is checked in Studio by runtest.ps1.
_gm = read("ReplicatedStorage/Shared/GunModels.lua")
# The creative guns' builders set their Flash kinds in their own module.
if os.path.exists(os.path.join(root, "ReplicatedStorage/Shared/GunModelsCreative.lua")):
    _gm += "\n" + read("ReplicatedStorage/Shared/GunModelsCreative.lua")
_fx = read("StarterPlayerScripts/GunFx.lua")
_vm = read("StarterPlayerScripts/Viewmodel.lua")
_cc = read("StarterPlayerScripts/CombatClient.client.lua")
_sc = read("ReplicatedStorage/Shared/SoundConfig.lua")
def _lua_table_keys(src, name):
    m = re.search(rf"^local {name} = \{{\n(.*?)^\}}", src, re.M | re.S)
    return set(re.findall(r"^\t(\w+) = ", m.group(1), re.M)) if m else set()
def _lua_string_map(src, name):
    m = re.search(rf"^local {name} = \{{([^}}]*)\}}", src, re.M)
    return dict(re.findall(r'(\w+) = "(\w+)"', m.group(1))) if m else {}
_gun_styles = set(re.findall(r"^STYLES\.(\w+) = ", _gm, re.M))
for _style in sorted(set(re.findall(r'style = "(\w+)"', read("ReplicatedStorage/Shared/WeaponData.lua")))):
    if _style not in _gun_styles: problems.append(f"GunModels has no STYLES.{_style} for WeaponData's {_style} guns")
_gun_flashes = set(re.findall(r'"(\w+)"', " ".join(re.findall(r'SetAttribute\("Flash", ([^\n]*)\)', _gm)))) | set(re.findall(r'\bflash = "(\w+)"', _gm))
_flash_kinds, _tracer_kinds = _lua_table_keys(_fx, "FLASH"), _lua_table_keys(_fx, "TRACER")
_shot_cue, _tracer_kind = _lua_string_map(_cc, "SHOT_CUE"), _lua_string_map(_cc, "TRACER_KIND")
if not _gun_styles or not _gun_flashes or not _flash_kinds or not _tracer_kinds or not _shot_cue or not _tracer_kind:
    problems.append("gun contract check: couldn't read STYLES, the Flash kinds, GunFx's FLASH/TRACER or CombatClient's SHOT_CUE/TRACER_KIND")
for _kind in sorted(_gun_flashes):
    if _kind not in _flash_kinds: problems.append(f"GunModels sets Flash \"{_kind}\", which GunFx's FLASH doesn't define")
    if _kind not in _shot_cue: problems.append(f"CombatClient's SHOT_CUE has no report for Flash \"{_kind}\"")
for _kind, _tracer in sorted(_tracer_kind.items()):
    if _tracer not in _tracer_kinds: problems.append(f"CombatClient sends Flash \"{_kind}\" tracers as \"{_tracer}\", which GunFx's TRACER doesn't define")
_gun_cues = (set(re.findall(r'"sound", "(\w+)"', _vm)) | set(_shot_cue.values())
             | set(_lua_string_map(_cc, "SHOT_CUE_BY_ID").values()) | set(re.findall(r'Sfx\.Play(?:At)?\("(\w+)"', _cc)))
for _cue in sorted(_gun_cues):
    if not re.search(rf"^\t{_cue} = \{{", _sc, re.M): problems.append(f"gun sound cue {_cue} isn't in SoundConfig")
print(f"guns: {len(_gun_styles)} styles, {len(_gun_flashes)} flash kinds, {len(_tracer_kind)} tracer kinds, {len(_gun_cues)} sound cues")

# --- Staged guns: an unfinished gun must not reach a player (claude-3b) --------------
# Ground and chest loot roll by weight, but BotService and SupplyDropService roll every gun of a rarity
# and ignore weights, so weights of 0 hide a gun from only two of the four ways it is found. `staged =
# true` is the flag all four honour, and the two must never disagree: a staged gun carrying a weight
# would roll as loot, and a creative gun with neither a weight nor the flag still reaches players
# through bot loot and supply drops -- which is how the fourteen creative guns leaked before the flag.
def _gun_staging(shared_files):
    found, staged = [], 0
    for rel, text in shared_files:
        gun, defs = None, {}
        for line in text.split("\n"):
            header = re.match(r"^\t(\w+) = \{", line)
            if header:
                gun = header.group(1)
                defs.setdefault(gun, {"staged": False, "weights": {}})
            if not gun:
                continue
            if re.search(r"\bstaged = true\b", line): defs[gun]["staged"] = True
            for field, value in re.findall(r"\b((?:ground|chest)Weight) = ([\d.]+)", line):
                defs[gun]["weights"][field] = float(value)
        for gun, info in sorted(defs.items()):
            live = sorted(f"{field} = {value:g}" for field, value in info["weights"].items() if value > 0)
            if info["staged"]:
                staged += 1
                if live: found.append(f"staged gun {gun} ({rel}) still rolls as loot: {', '.join(live)}")
            elif rel.endswith("CreativeArsenal.lua") and info["weights"] and not live:
                found.append(f"{gun} ({rel}) has no loot weight and no `staged = true`: bot loot and supply drops hand it out anyway")
    return found, staged
_staging_files = [(rel, text) for rel, text in lua_files() if rel.startswith(os.path.join("ReplicatedStorage", "Shared"))]
_staging_problems, _staged_guns = _gun_staging(_staging_files)
problems.extend(_staging_problems)
# Both halves have to fire: a weight on a staged gun, and a staged flag dropped without one.
_with_weight = [(rel, text.replace("staged = true, groundWeight = 0", "staged = true, groundWeight = 7", 1)) for rel, text in _staging_files]
_without_flag = [(rel, text.replace("staged = true, ", "", 1) if rel.endswith("CreativeArsenal.lua") else text) for rel, text in _staging_files]
if not _gun_staging(_with_weight)[0]: problems.append("staging: the check missed a planted loot weight on a staged gun; it isn't testing anything")
if not _gun_staging(_without_flag)[0]: problems.append("staging: the check missed a planted unstaged gun with no weight; it isn't testing anything")
# The flag only gates anything if the rolls read it. Informational until both land (other tabs' files).
_readers = [name for name, rel in (("BotService", "ServerScriptService/Modules/BotService.lua"),
                                   ("SupplyDropService", "ServerScriptService/Modules/SupplyDropService.lua"),
                                   ("LobbyService", "ServerScriptService/Modules/LobbyService.lua"))
            if os.path.exists(os.path.join(root, rel)) and ".staged" in read(rel)]
print(f"staging: {_staged_guns} staged guns, weight-free; skipped by {', '.join(_readers) if _readers else 'nothing yet'}")

# A gun's killEffect names a function in DeathFxService's EFFECTS table, and a name that isn't there
# falls back to a ragdoll without a word (DeathFxService: `EFFECTS[effect] or EFFECTS.ragdoll`), so a
# typo costs a gun its whole death animation silently.
_death_effects = set(re.findall(r"^EFFECTS\.(\w+) = function", read("ServerScriptService/Modules/DeathFxService.lua"), re.M))
def _kill_effects(shared_files):
    found = []
    for rel, text in shared_files:
        for m in re.finditer(r"^\t(\w+) = \{\n(.*?)^\t\},", text, re.M | re.S):
            effect = re.search(r'\bkillEffect = "(\w+)"', m.group(2))
            if effect and effect.group(1) not in _death_effects:
                found.append(f"{m.group(1)} ({rel}) has killEffect \"{effect.group(1)}\", which DeathFxService has no EFFECTS entry for (it would ragdoll instead)")
    return found
if not _death_effects: problems.append("kill effects: couldn't read DeathFxService's EFFECTS table")
problems.extend(_kill_effects(_staging_files))
_planted_effect = [(rel, text.replace('killEffect = "confetti"', 'killEffect = "confettti"', 1)) for rel, text in _staging_files]
if not _kill_effects(_planted_effect): problems.append("kill effects: the check missed a planted typo (\"confettti\"); it isn't testing anything")
print(f"kill effects: {len(_death_effects)} in DeathFxService")

# Two arsenals declaring the same weapon id is not a merge conflict anyone sees: WeaponData's
# registration asserts on it, so the whole game fails to load, with a message naming whichever pack
# happened to register second. Cheaper to catch here, before Studio.
def _duplicate_ids(shared_files):
    seen, found = {}, []
    for rel, text in sorted(shared_files):
        for m in re.finditer(r"^\t(\w+) = \{\n(.*?)^\t\},", text, re.M | re.S):
            # A gun, not a cosmetic or a brainrot that also carries a rarity: only guns have these.
            if not (re.search(r'\brarity = "', m.group(2)) and re.search(r"\b(?:fireRate|magSize) = ", m.group(2))): continue
            gun = m.group(1)
            if gun in seen and seen[gun] != rel: found.append(f"weapon id {gun} is declared in both {seen[gun]} and {rel} (WeaponData asserts on the second one and the game won't load)")
            seen.setdefault(gun, rel)
    return found, len(seen)
_dupe_problems, _weapon_ids = _duplicate_ids(_staging_files)
problems.extend(_dupe_problems)
_planted_dupe = _staging_files + [("ReplicatedStorage/Shared/_PlantedArsenal.lua", "\tSahurPistol = {\n\t\trarity = \"Common\", fireRate = 4,\n\t},\n")]
if not _duplicate_ids(_planted_dupe)[0]: problems.append("weapon ids: the duplicate check missed a planted clash; it isn't testing anything")
print(f"weapon ids: {_weapon_ids} across the arsenals, no clashes")

# --- Progression: Rot Rank, Brain Cells, mastery, the Rot Index, the Cell Shop (claude-a4) --------
# Progression pays in Brain Cells, which must never be buyable or boosted by a pass, and must not
# undo the Legendary+ scarcity checked above: the Cell Shop stops below Legendary and sells no crates,
# and rank rewards are a handful of crates below Legendary. Its hooks live in files owned by others,
# so a stale copy pasted over one of them would silently switch a system off; each is checked here.
# The behaviour itself is measured by tools/progression_probe.lua, the numbers by progression_model.py.
_pd = read("ReplicatedStorage/Shared/ProgressionData.lua")
_ps = read("ServerScriptService/Modules/ProgressionService.lua")
_pshop = re.search(r"ProgressionData\.ShopSlots = \{\n(.*?)\n\}", _pd, re.S)
_pslots = re.findall(r'\{ id = "(\w+)", kind = "(\w+)",(?: rarity = "(\w+)",)?', _pshop.group(1)) if _pshop else []
_pceiling = re.search(r'ShopRarityCeiling = "(\w+)"', _pd)
if not _pslots or not _pceiling:
    problems.append("progression: couldn't read ProgressionData.ShopSlots or ShopRarityCeiling")
elif _pshop.group(1).count("{ id =") != len(_pslots):
    # A slot written in another order (rarity before kind, say) would otherwise skip every check below.
    problems.append(f"progression: only {len(_pslots)} of {_pshop.group(1).count('{ id =')} Cell Shop slots could be read; write each as {{ id, kind, rarity, ... }}")
elif RARITIES.index(_pceiling.group(1)) > RARITIES.index("Legendary"):
    problems.append(f"progression: the Cell Shop ceiling is {_pceiling.group(1)}; it must stay at Legendary (nothing Legendary or rarer)")
for _id, _kind, _rarity in _pslots:
    if _kind not in ("Brainrot", "Snack"): problems.append(f"progression: Cell Shop slot {_id} sells {_kind}; only brainrots and snacks (no crates)")
    if _rarity and _pceiling and RARITIES.index(_rarity) >= RARITIES.index(_pceiling.group(1)):
        problems.append(f"progression: Cell Shop slot {_id} sells {_rarity}, at or above the {_pceiling.group(1)} ceiling")
_prc = re.search(r"ProgressionData\.RankCrates = \{([^}]*)\}", _pd)
_prank_crates = re.findall(r'\[(\d+)\] = "(\w+)"', _prc.group(1)) if _prc else None
if _prank_crates is None: problems.append("progression: couldn't read ProgressionData.RankCrates")
else:
    if len(_prank_crates) > 5: problems.append(f"progression: {len(_prank_crates)} rank reward crates per prestige; the ceiling is 5")
    for _r, _c in _prank_crates:
        if _c not in RARITIES or RARITIES.index(_c) >= RARITIES.index("Legendary"): problems.append(f"progression: rank {_r} pays a {_c} Crate; rank crates stay below Legendary")
# Rank rewards are paid per rank, once. `paidRank` is what makes a re-tune of the curve safe: without
# it, halving the curve would pay every player again for ranks their stored XP suddenly reaches.
# Commented-out code is not code, so these read the two sources with their comments stripped.
_pd_code, _ps_code = (re.sub(r"--[^\n]*", "", _t) for _t in (_pd, _ps))
if not re.search(r"paidRank\s*=\s*0\b", _pd_code): problems.append("progression: ProgressionData.Default has no paidRank = 0; rank rewards could be paid twice after a curve change")
if not re.search(r"clean\.paidRank\s*=\s*whole\(saved\.paidRank", _pd_code): problems.append("progression: ProgressionData.Reconcile doesn't carry paidRank through, so a save would forget which ranks were paid")
if not re.search(r"for\s+\w+\s*=\s*math\.max\(\s*before\s*,\s*progression\.paidRank\s*\)\s*\+\s*1", _ps_code):
    problems.append("progression: AddXp doesn't pay from math.max(before, progression.paidRank) + 1; paying only for ranks crossed in the call would re-pay or skip ranks when the curve changes")
if not re.search(r"progression\.paidRank\s*=\s*math\.max\(progression\.paidRank", _ps_code): problems.append("progression: AddXp doesn't raise progression.paidRank after paying, so the same ranks would pay again")
if not re.search(r"progression\.paidRank\s*=\s*1\b", _ps_code): problems.append("progression: Prestige doesn't reset paidRank to 1, so a new prestige's ranks would never pay")
if not re.search(r"progression\.paidRank\s*=\s*rank\b", _ps_code): problems.append("progression: the pass-XP backfill doesn't mark its ranks paid, so an old profile would be paid for them twice")
# A row sized `UDim2.new(1, -N)` inside the progression pages is right at 728 px of content and
# NEGATIVE at the 296 a phone gives in portrait -- and a negative width draws NOTHING in Roblox, so the
# row goes blank with no sign of what happened. Small offsets are card padding and are fine; anything
# from 150 up was a column laid out against a width that no longer exists. Measured widths (`span`) and
# UiParts.grid replaced them; tools/progression_width_probe.lua proves it at six widths.
# Comment-stripped, or the sentence explaining the rule trips the rule.
_ppanel = re.sub(r"--[^\n]*", "", read("StarterPlayerScripts/ProgressionPanel.lua"))
_pfixed = sorted({int(_m) for _m in re.findall(r"UDim2\.new\(1,\s*-(\d+)", _ppanel) if int(_m) >= 150})
if _pfixed: problems.append(f"progression: ProgressionPanel sizes rows with fixed offsets {_pfixed}; at 296 px of content those go negative and draw nothing -- size from the measured page (span/UiParts.grid) instead")
# Toasts go through `announce`, which pcalls and warns. A bare StateSync.Notify in ProgressionService
# throws out of whatever paid the reward it was announcing, leaving Cells paid and the nameplate,
# the title counters and the client state stale (the live-server probe found exactly that).
# Same for pushes: StateSync.Push fires a remote, so it goes through pushNow(), which pcalls and warns.
_ppush = len(re.findall(r"StateSync\.Push", _ps_code))
if _ppush != 1: problems.append(f"progression: ProgressionService names StateSync.Push {_ppush} times; only pushNow() may call it, so a failed push can't fail the claim or purchase that earned it")
_pnotify = len(re.findall(r"StateSync\.Notify", _ps_code))
if _pnotify != 1: problems.append(f"progression: ProgressionService names StateSync.Notify {_pnotify} times; only announce() may call it, so a toast that throws can't undo the reward it announces")
if not re.search(r"for id(?:, def)? in pairs\(WeaponData\.Weapons\) do", _pd): problems.append("progression: ProgressionData.MasteryWeapons isn't built from WeaponData.Weapons; a hard-coded list would leave new guns without mastery")
if "def.staged" not in _pd: problems.append("progression: MasteryWeapons no longer skips staged guns, so the Mastery page would list guns nobody can get")
for _rel in ("ServerScriptService/Modules/Monetization.lua", "ReplicatedStorage/Shared/GamepassConfig.lua"):
    if re.search(r"(?i)brain ?cells?|progression|\bcells?\b", read(_rel)): problems.append(f"progression: {_rel} mentions Brain Cells / progression; Cells must never be sold or boosted")
if re.search(r"Monetization|AddCoins|EarnCoins|SahurCoins", re.sub(r"--[^\n]*", "", _ps)): problems.append("progression: ProgressionService touches coins or Monetization; it pays Cells only (titles pay their coins through AchievementService)")
_phooks = [
    ("ServerScriptService/Modules/PlayerData.lua", "Progression = ProgressionData.Default()", "the Progression default"),
    ("ServerScriptService/Modules/PlayerData.lua", "data.Progression = ProgressionData.Reconcile(saved.Progression)", "the Progression reconcile"),
    ("ServerScriptService/Modules/PlayerData.lua", "rankScore = 0, mastered = 0, rotmasters = 0, discovered = 0", "the progression Lifetime counters"),
    ("ServerScriptService/Modules/BattlePassService.lua", "BattlePassService.OnXp(player, amount)", "the pass XP hook"),
    ("ServerScriptService/Modules/MatchService.lua", "MatchService.OnKillCredited(killerToken, token, weaponId)", "the credited-kill hook"),
    ("ServerScriptService/Modules/MatchService.lua", "eliminate(victim, killer, method, weaponId)", "weaponId passed into eliminate"),
    ("ServerScriptService/Modules/StateSync.lua", "progression = ProgressionData.Snapshot(data, os.time())", "the progression snapshot"),
    ("ServerScriptService/Modules/NameplateService.lua", 'GetAttribute("RotRank")', "the Rot Rank nameplate"),
    ("ServerScriptService/Bootstrap.server.lua", "BattlePassService.OnXp = ProgressionService.OnPassXp", "the OnXp wiring"),
    ("ServerScriptService/Bootstrap.server.lua", "MatchService.OnKillCredited = ProgressionService.OnKillCredited", "the OnKillCredited wiring"),
    ("ServerScriptService/Bootstrap.server.lua", "ProgressionService.OnProfileLoaded(player)", "the join hook"),
    ("StarterPlayerScripts/MenuClient.client.lua", "ProgressionPanel.Render(content, profile, { rerender = renderTab, noTabs = true })", "the Pass tab hub"),
    # Robux never turns into Brain Cells: purchased brainrots and pulls from Robux crates are logged as Purchased.
    ("ServerScriptService/Bootstrap.server.lua", "if pulled and result.purchased then", "the Robux crate pull check in openCrateFor"),
    ("ServerScriptService/Modules/ProgressionService.lua", "elseif state == ProgressionData.Purchased then", "ClaimIndex refusing Purchased entries"),
    ("ServerScriptService/Modules/TradeService.lua", "pcall(TradeService.OnTradeMoved, session.a, session.b, offerA, offerB)", "the protected trade hook (Purchased can't be laundered by trading)"),
    ("ServerScriptService/Bootstrap.server.lua", "TradeService.OnTradeMoved = ProgressionService.OnTradeMoved", "the OnTradeMoved wiring"),
    # The results card's progression line.
    ("ServerScriptService/Bootstrap.server.lua", "ProgressionService.BeginMatch()", "the match-start snapshot"),
    ("ServerScriptService/Bootstrap.server.lua", "MatchService.ProgressionSummary = ProgressionService.MatchSummary", "the MatchSummary wiring"),
    ("ServerScriptService/Modules/MatchService.lua", "progression = MatchService.ProgressionSummary and MatchService.ProgressionSummary(token) or nil", "the results payload field"),
    ("StarterPlayerScripts/HudClient.client.lua", "local progression = result.progression", "the results card line"),
]
# Rank-reward cosmetics: every ProgressionData.RankCosmetics entry is a priceless rankOnly cosmetic, every
# rankOnly cosmetic has an entry (nothing unobtainable), each prestige has exactly one, ids follow the
# Prestige/Mastery/Cell prefix MenuClient's HOW button relies on, and OfKind keeps them out of crates,
# the coin shop, bot outfits and the Daily Spin.
_pcos = read("ReplicatedStorage/Shared/CosmeticData.lua")
_prc_block = re.search(r"ProgressionData\.RankCosmetics = \{\n(.*?)\n\}", _pd, re.S)
_prank_cos = re.findall(r'\{ id = "(\w+)", (\w+) = (\d+)', _prc_block.group(1)) if _prc_block else []
if not _prank_cos: problems.append("progression: couldn't read ProgressionData.RankCosmetics")
_prank_only = {m.group(1): m.group(2) for m in re.finditer(r"^\t(\w+) = \{\n(.*?)^\t\},", _pcos, re.S | re.M) if "rankOnly = true" in m.group(2)}
for _cid, _kind, _value in _prank_cos:
    if _cid not in _prank_only: problems.append(f"progression: RankCosmetics names {_cid}, which isn't a rankOnly cosmetic in CosmeticData")
    elif "price =" in _prank_only[_cid]: problems.append(f"progression: rank cosmetic {_cid} has a coin price; rank rewards are never sold for coins")
    if not re.match(r"(Prestige|Mastery|Cell)", _cid): problems.append(f"progression: rank cosmetic id {_cid} must start with Prestige, Mastery or Cell")
for _cid in _prank_only:
    if _cid not in {c for c, _, _ in _prank_cos}: problems.append(f"progression: rankOnly cosmetic {_cid} has no RankCosmetics entry, so nothing can ever unlock it")
_pmax_prestige = int(re.search(r"ProgressionData\.MaxPrestige = (\d+)", _pd).group(1))
_pprestiges = sorted(int(v) for _, k, v in _prank_cos if k == "prestige")
if _pprestiges != list(range(1, _pmax_prestige + 1)): problems.append(f"progression: prestige cosmetics cover {_pprestiges}, expected one each for 1..{_pmax_prestige}")
if "not item.rankOnly" not in re.search(r"function CosmeticData\.OfKind\(.*?\nend", _pcos, re.S).group(0):
    problems.append("progression: CosmeticData.OfKind doesn't leave out rankOnly cosmetics, so crates, the shop or the Daily Spin could hand them out")
# The Robux brainrot grant marks what it bought as Purchased, called directly or through a pcall, inside
# that grant handler (anywhere else it wouldn't run before a scan).
_pgrant = re.search(r'RegisterGrantHandler\("Brainrot",(.*?)\nend\)', read("ServerScriptService/Bootstrap.server.lua"), re.S)
if not _pgrant or not re.search(r"ProgressionService\.RecordPurchased(\(|, )player, def\.name", _pgrant.group(1)):
    problems.append("progression: Bootstrap's Robux \"Brainrot\" grant handler no longer calls ProgressionService.RecordPurchased(player, def.name)")
# The trade hook must run after the brainrots move and before the first save yields; anywhere later, a
# scan during that yield could record a copy bought with Robux as found in play.
_ptrade = read("ServerScriptService/Modules/TradeService.lua")
_pm, _ph, _psave = _ptrade.find("move(dataB, dataA, offerB)"), _ptrade.find("pcall(TradeService.OnTradeMoved"), _ptrade.find("PlayerData.Save(session.a)")
if not (0 <= _pm < _ph < _psave): problems.append("progression: TradeService's OnTradeMoved hook must sit between the moves and PlayerData.Save")
# Page bonuses count Claimed entries only, so a Purchased one can never complete a page.
_pcounts = re.search(r"function ProgressionData\.IndexCounts\(index\)(.*?)\nend", _pd, re.S)
if not _pcounts or "if state == ProgressionData.Claimed then" not in _pcounts.group(1) or "Purchased" in _pcounts.group(1):
    problems.append("progression: IndexCounts must count only Claimed entries as claimed (a Purchased entry must never complete a page)")
for _rel, _needle, _what in _phooks:
    if _needle not in read(_rel): problems.append(f"progression: {_rel} lost {_what} (`{_needle}`)")
_boot = read("ServerScriptService/Bootstrap.server.lua")
for _remote in ("Prestige", "ClaimIndex", "BuyCellOffer"):
    _m = re.search(rf'Remotes\.Function\("{_remote}"\)\.OnServerInvoke = guard\(function\(player[^)]*\)\n\tif ProgressionService\.RateLimited\(player, "{_remote}"\)', _boot)
    if not _m: problems.append(f"progression: Bootstrap's {_remote} remote isn't guarded and rate-limited first")
_ach = read("ReplicatedStorage/Shared/AchievementData.lua")
for _stat in ("rankScore", "mastered", "rotmasters", "discovered"):
    if f'"{_stat}"' not in _ach.split("AchievementData.LifetimeStats")[-1]: problems.append(f"progression: AchievementData.LifetimeStats is missing {_stat}")
print(f"progression: {len(_pslots)} Cell Shop slots below {_pceiling.group(1) if _pceiling else '?'}, {len(_prank_crates or [])} rank crates, {len(_phooks)} hooks in place")

# --- Parachutes: designs, cosmetics, the shop draw and the equip path (claude-df) ---------------
# Every Parachute cosmetic has a design and every design a cosmetic; every rarity has at least one;
# Common to Epic are sold, Legendary and up are crate exclusives; no canopy uses Neon or anything
# see-through; and the save, sync, equip, shop and drop-in wiring are all in place.
_chute_src = read("ReplicatedStorage/Shared/ParachuteModels.lua")
_chute_designs = set(re.findall(r"^DESIGNS\.(\w+) = function\(k\)", _chute_src, re.M))
_chute_order_m = re.search(r"ParachuteModels\.Order = \{(.*?)\}", _chute_src, re.S)
_chute_order = re.findall(r'"(\w+)"', _chute_order_m.group(1)) if _chute_order_m else []
if set(_chute_order) != _chute_designs or len(_chute_order) != len(_chute_designs):
    problems.append(f"parachutes: ParachuteModels.Order {sorted(_chute_order)} doesn't list each design once: {sorted(_chute_designs)}")
_chute_items = {}
for _m in re.finditer(r"^\t(\w+) = \{\n(.*?)^\t\},", items_block, re.S | re.M):
    if 'kind = "Parachute"' in _m.group(2):
        _chute_items[_m.group(1)] = _m.group(2)
for _id in sorted(set(_chute_items) - _chute_designs): problems.append(f"parachutes: cosmetic {_id} has no design in ParachuteModels")
for _id in sorted(_chute_designs - set(_chute_items)): problems.append(f"parachutes: design {_id} has no Parachute cosmetic in CosmeticData")
_chute_rarities = {}
for _id, _body in _chute_items.items():
    _rar = re.search(r'rarity = "(\w+)"', _body)
    _rar = _rar.group(1) if _rar else "?"
    _chute_rarities.setdefault(_rar, []).append(_id)
    _sold = "price =" in _body
    if _rar in ("Common", "Uncommon", "Rare", "Epic") and not _sold: problems.append(f"parachutes: {_id} is {_rar} but has no price")
    if _rar in ("Legendary", "Mythic", "Secret") and ("crateOnly = true" not in _body or _sold): problems.append(f"parachutes: {_id} is {_rar} but isn't a price-less crate exclusive")
for _rar in RARITIES:
    if not _chute_rarities.get(_rar): problems.append(f"parachutes: no parachute of rarity {_rar} (a Parachute Crate roll there would only refund)")
# (`0(?![.\d])` so a fractional transparency such as 0.5 counts; the first version let it through.)
if re.search(r"Material\.(Neon|Glass|ForceField)\b|Transparency = (?!0(?![.\d]))", _chute_src): problems.append("parachutes: ParachuteModels uses Neon, glass or transparency")
for _rel, _needle, _what in [
    ("ServerScriptService/Modules/PlayerData.lua", "parachute = nil", "the Cosmetics.parachute default"),
    ("ServerScriptService/Modules/PlayerData.lua", "data.Cosmetics.parachute = saved.Cosmetics.parachute", "reading Cosmetics.parachute back"),
    ("ServerScriptService/Modules/RewardService.lua", 'Parachute = "parachute"', "the Parachute equip slot"),
    ("ServerScriptService/Modules/RewardService.lua", "data.Cosmetics.parachute = nil", "clearing the parachute with the other slots"),
    ("ServerScriptService/Modules/StateSync.lua", "parachute = data.Cosmetics.parachute", "syncing the equipped parachute"),
    ("ReplicatedStorage/Shared/ShopRotation.lua", 'drawCosmetics(Random.new(window * 6311 + 29), "Parachute", ShopRotation.ParachuteSlots, cosmetics)', "the parachute draw on its own Random"),
    ("ServerScriptService/Bootstrap.server.lua", "MovementService.ParachuteFor = function(character)", "the ParachuteFor hook"),
    ("StarterPlayerScripts/MenuClient.client.lua", "cosmetics.parachute == id", "the menu's equipped-parachute check"),
    ("StarterPlayerScripts/MenuClient.client.lua", "parachutePreview(buttons.Parent, id)", "the parachute row preview"),
]:
    if _needle not in read(_rel): problems.append(f"parachutes: {_rel} lost {_what} (`{_needle}`)")
print(f"parachutes: {len(_chute_designs)} designs, {len(_chute_items)} cosmetics, " + ", ".join(f"{_r} {len(_chute_rarities.get(_r, []))}" for _r in RARITIES))

# --- Accessories: pieces spaced round a ring must clear each other (claude-df) --------------------
# Pieces on a ring turn about Y, which never turns their tops and bottoms, so any two that overlap
# have faces in one plane and AccessoryService's z-fight pass resolves them by stepping one piece off
# the ring. It did exactly that to the Crown of Rot (ten teeth 0.36 wide where the ring clears 0.318:
# 18 pieces moved, the worst by 0.60, a staircase on every wearer) and to the Golden Halo. The pieces
# come closest at their inner corners, so the limit is the arc there: 2 * (radius - depth / 2) *
# tan(pi / count). This is arithmetic on the numbers as written, so it catches the next one before
# anybody wears it.
import math  # only this section needs it

_acc_src = read("ReplicatedStorage/Shared/CosmeticData.lua")
_ring_calls = [(m, "ring") for m in re.finditer(
    r"\bring\(\s*(\d+)\s*,\s*([\d.]+)\s*,\s*[-\d.]+\s*,\s*Vector3\.new\(\s*([\d.]+)\s*,\s*[\d.]+\s*,\s*([\d.]+)\s*\)", _acc_src)]
_ring_calls += [(m, "points") for m in re.finditer(
    r"\bpoints\(\s*(\d+)\s*,\s*([\d.]+)\s*,\s*[-\d.]+\s*,\s*[\d.]+\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*", _acc_src)]
_tightest, _tightest_at = None, ""
for _m, _kind in _ring_calls:
    _count, _radius, _width, _depth = int(_m.group(1)), float(_m.group(2)), float(_m.group(3)), float(_m.group(4))
    _line = _acc_src.count("\n", 0, _m.start()) + 1
    _limit = 2 * (_radius - _depth / 2) * math.tan(math.pi / _count)
    _margin = _limit - _width
    if _margin <= 0:
        problems.append(f"accessories: CosmeticData.lua:{_line} {_kind}({_count}, {_radius}) pieces are {_width} wide but "
                        f"the ring gives each {_limit:.3f} at the inner corners, so neighbours overlap with their faces in "
                        f"one plane and the build pass will step them off the ring")
    elif _margin < 0.005:
        problems.append(f"accessories: CosmeticData.lua:{_line} {_kind}({_count}, {_radius}) clears by only {_margin:.4f} -- "
                        f"too fine to trust; thin the ring (the limit scales with radius - depth / 2) or drop a piece")
    if _tightest is None or _margin < _tightest:
        _tightest, _tightest_at = _margin, f"{_kind} at line {_line}"
if _ring_calls:
    print(f"accessories: {len(_ring_calls)} rings of pieces, tightest clearance {_tightest:.3f} ({_tightest_at})")

# --- Explosives, grenades, smoke and hit splats (claude-a4 [e8e0d6]) ------------------------------
# ProjectileService flies launcher rounds and thrown items, HitSplatService batches hits, and both
# reach the game through hooks in files other tabs own. A stale paste over one of those would switch
# the system off without a word (launchers back to hitscan, grenades that can't be thrown, bots that
# see through smoke), so each hook is asserted here. So are the data contracts: every `projectile`
# kind has a Ballistics spec, every throwable item has a Ballistics spec and a ThrowableModels
# builder, and every cue the clients play is in SoundConfig. The behaviour itself is measured by
# tools/projectile_probe.lua; the renders by tools/throwables_gallery.lua.
_explosive_hooks = [
    ("ServerScriptService/Modules/CombatService.lua", "function CombatService.OnDamage(fn)", "the damage listener hook"),
    ("ServerScriptService/Modules/CombatService.lua", "for _, listener in ipairs(CombatService.DamageListeners) do", "the damage listener loop in DealDamage"),
    ("ServerScriptService/Modules/CombatService.lua", "if def.projectile and CombatService.LaunchProjectile then", "the launcher branch in Fire"),
    ("ServerScriptService/Modules/CombatService.lua", "CombatService.LaunchProjectile = nil", "the LaunchProjectile hook"),
    ("ServerScriptService/Modules/BotService.lua", "CombatService.SmokeBlocks(fromPart.Position, toPart.Position)", "the smoke check in hasLineOfSight"),
    ("ReplicatedStorage/Shared/ItemModels.lua", 'if item.kind == "throwable" then', "the ThrowableModels delegate"),
    ("ServerScriptService/Modules/WeaponService.lua", "WeaponService.ThrowEffect = function()", "the ThrowEffect default"),
    ("ServerScriptService/Modules/WeaponService.lua", 'elseif item.kind == "throwable" then', "the throwable use branch"),
    ("ServerScriptService/Modules/LootService.lua", "ItemData.RollThrowable()", "throwables in chests and on the ground"),
    ("ReplicatedStorage/Shared/ItemData.lua", "function ItemData.RollThrowable()", "the throwable roll"),
    ("ServerScriptService/Bootstrap.server.lua", 'require(Modules:WaitForChild("ProjectileService"))', "the ProjectileService require"),
    ("ServerScriptService/Bootstrap.server.lua", 'require(Modules:WaitForChild("HitSplatService"))', "the HitSplatService require"),
    ("ServerScriptService/Bootstrap.server.lua", "ProjectileService.Clear()", "the match Clear"),
    ("ServerScriptService/Modules/ProjectileService.lua", "CombatService.LaunchProjectile = function(player, def, origin, direction)", "ProjectileService setting LaunchProjectile"),
    ("ServerScriptService/Modules/ProjectileService.lua", "CombatService.SmokeBlocks = ProjectileService.SmokeBlocks", "ProjectileService setting SmokeBlocks"),
    ("ServerScriptService/Modules/ProjectileService.lua", "WeaponService.ThrowEffect = function(player, itemId, aimPoint)", "ProjectileService setting ThrowEffect"),
    ("ServerScriptService/Modules/HitSplatService.lua", "CombatService.OnDamage(HitSplatService.OnHit)", "HitSplatService registering for hits"),
]
for _rel, _needle, _what in _explosive_hooks:
    if _needle not in read(_rel): problems.append(f"explosives: {_rel} lost {_what} (`{_needle}`)")
_bal = read("ReplicatedStorage/Shared/Ballistics.lua")
def _lua_block_keys(src, header):
    body = src.split(header, 1)[1].split("\n}", 1)[0] if header in src else ""
    return set(re.findall(r"^\t(\w+) = \{", body, re.M))
_round_specs = _lua_block_keys(_bal, "Ballistics.Rounds = {")
_throw_specs = _lua_block_keys(_bal, "Ballistics.Throwables = {")
# Every gun's `projectile` kind, wherever the gun is declared (WeaponData, the arsenal pack, the creative
# arsenal, any later Shared module), must be a kind registered somewhere: a key of Ballistics.Rounds or
# a Ballistics.RegisterRound("kind", ...) call in any Shared file. A kind-name typo would otherwise
# fire nothing, silently. Guns are matched to the nearest `\tName = {` above their `projectile` field.
def _projectile_contract(shared_files):
    guns, kinds, found = {}, set(_round_specs), []
    for rel, text in shared_files:
        kinds |= set(re.findall(r'Ballistics\.RegisterRound\(\s*"(\w+)"', text))
        gun = None
        for line in text.split("\n"):
            m = re.match(r"^\t(\w+) = \{", line)
            if m: gun = m.group(1)
            k = re.search(r'\bprojectile = "(\w+)"', line)
            if k and gun: guns[gun] = (k.group(1), rel)
    for gun, (kind, rel) in sorted(guns.items()):
        if kind not in kinds: found.append(f"explosives: {rel}: {gun} fires projectile \"{kind}\", which no Shared module registers (Ballistics.Rounds or Ballistics.RegisterRound)")
    return guns, kinds, found
_shared_files = [(rel, text) for rel, text in lua_files() if rel.startswith(os.path.join("ReplicatedStorage", "Shared"))]
_projectile_guns, _round_kinds, _kind_problems = _projectile_contract(_shared_files)
problems.extend(_kind_problems)
for _gun in ("CappuccinaLauncher", "TralalaThumper"):
    if _gun not in _projectile_guns: problems.append(f"explosives: {_gun} no longer carries `projectile` (it would be hitscan again)")
# The check has to fire: a planted typo in a copy of WeaponData must be caught, or it's a test that doesn't test.
_planted = [(rel, text.replace('projectile = "rocket"', 'projectile = "rockett"', 1) if rel.endswith("WeaponData.lua") else text) for rel, text in _shared_files]
if not _projectile_contract(_planted)[2]: problems.append("explosives: the projectile-kind check missed a planted typo (\"rockett\"); it isn't testing anything")
_items_src = read("ReplicatedStorage/Shared/ItemData.lua")
_throwables = re.findall(r'^\t(\w+) = \{\n\t\tname = "[^"]+",\n\t\tkind = "throwable"', _items_src, re.M)
_builders = set(re.findall(r"^\t(\w+) = build\w+,", read("ReplicatedStorage/Shared/ThrowableModels.lua").split("local BUILDERS = {", 1)[-1].split("\n}", 1)[0], re.M))
if not _throwables: problems.append("explosives: ItemData has no throwable items")
for _id in _throwables:
    if _id not in _throw_specs: problems.append(f"explosives: throwable {_id} has no Ballistics.Throwables spec")
    if _id not in _builders: problems.append(f"explosives: throwable {_id} has no ThrowableModels builder")
    if f'"{_id}"' not in _items_src.split("ItemData.Order = {", 1)[-1].split("\n}", 1)[0]: problems.append(f"explosives: throwable {_id} isn't in ItemData.Order (it would never roll)")
_pc_src, _hc_src, _ef_src = read("StarterPlayerScripts/ProjectileClient.client.lua"), read("StarterPlayerScripts/HitSplatClient.client.lua"), read("StarterPlayerScripts/ExplosiveFx.lua")
_explosive_cues = set(re.findall(r'Sfx\.Play(?:At)?\("(\w+)"', _pc_src + _hc_src)) | set(re.findall(r'"(Explosion\w+)"', _pc_src)) | set(re.findall(r'ExplosiveFx\.Loop\("(\w+)"', _pc_src))
for _cue in sorted(_explosive_cues):
    if not re.search(rf"^\t{_cue} = \{{", _sc, re.M): problems.append(f"explosives: sound cue {_cue} isn't in SoundConfig")
if "CanQuery = false" not in _ef_src: problems.append("explosives: ExplosiveFx parts must be CanQuery = false, or crosshairs and shots would hit smoke and fireballs")
print(f"explosives: {len(_projectile_guns)} projectile guns over {len(_round_kinds)} registered round kinds ({len(_round_specs)} built in), {len(_throwables)} throwables, {len(_explosive_cues)} cues, {len(_explosive_hooks)} hooks in place")

# --- Roads ----------------------------------------------------------------------
# The road network is split across RoadNetwork (planning, heights, building), MapDecor (surfaces,
# junctions, lights and signs), MapTerrain (the ground under the roads, bridges) and a client
# script that runs the traffic lights, so the contracts between them are checked here.
_road_roads_src = read("ServerScriptService/Modules/RoadNetwork.lua")
_road_decor_src = read("ServerScriptService/Modules/MapDecor.lua")
_road_gen_src = read("ServerScriptService/Modules/MapGenerator.lua")
_road_terrain_src = read("ServerScriptService/Modules/MapTerrain.lua")
_road_traffic_src = read("StarterPlayerScripts/TrafficClient.client.lua")

# A road runs straight on out of a town's street, so the two must be the same width.
_road_road_width = re.search(r"RoadNetwork\.Width = (\d+)", _road_roads_src)
_road_main_street = re.search(r"local MAIN_STREET = (\d+)", _road_gen_src)
if not _road_road_width or not _road_main_street or _road_road_width.group(1) != _road_main_street.group(1):
    problems.append("RoadNetwork.Width must equal MapGenerator's MAIN_STREET: a road continues a town's street flush")

# Every attribute a signal lamp is given is what the client reads to run it, and the tag matches.
_road_lamp_attrs = set(re.findall(r'lamp:SetAttribute\("(\w+)"', _road_decor_src))
_road_client_attrs = set(re.findall(r'GetAttribute\("(\w+)"\)', _road_traffic_src))
if not _road_lamp_attrs:
    problems.append("MapDecor no longer sets attributes on signal lamps (TrafficClient has nothing to run them by)")
elif _road_lamp_attrs != _road_client_attrs:
    problems.append(f"signal lamp attributes set by MapDecor {sorted(_road_lamp_attrs)} != read by TrafficClient {sorted(_road_client_attrs)}")
if 'AddTag(lamp, "TrafficLamp")' not in _road_decor_src or '"TrafficLamp"' not in _road_traffic_src:
    problems.append("MapDecor and TrafficClient must agree on the TrafficLamp tag")

# The build order the roads depend on: planned and claimed before any ground is written, the
# river planned before the ground is shaped (so each bridge sits on a straight stretch of road), the
# ground shaped under the roads in the relief pass, and the roads built before the towns, which
# need to know which street ends a road leaves from.
for _road_needle, _road_why in [
    ("RoadNetwork.Plan(", "MapGenerator must plan the road network"),
    ("roads:Claim(space)", "MapGenerator must claim the road corridors before anything else is placed"),
    ("MapTerrain.PlanRiver(", "MapGenerator must plan the river before the ground is shaped"),
    ("MapTerrain.RoadCrossings(", "the roads must be told where the planned river crosses them"),
    ("MapTerrain.Relief(terrain, preset, radius, centers, townSpread, roads, roadCrossings)", "the relief pass must shape the ground under the roads"),
    ("roads:Build(", "MapGenerator must build the roads"),
    ("roads:MouthsOf(index)", "towns must be told which street ends a road leaves from"),
    ("buildTown(map", "MapGenerator must build the towns (the build-order check below needs this call)"),
]:
    if _road_needle not in _road_gen_src:
        problems.append(_road_why + f" (missing `{_road_needle}`)")
if "roads:ComputeHeights(heightAt, preset, roadCrossings)" not in _road_terrain_src or "roads:GroundAt(" not in _road_terrain_src:
    problems.append("MapTerrain.Relief must compute road heights (with the river crossings) and shape the ground with RoadNetwork:GroundAt")
_road_gen_order = [_road_gen_src.find(n) for n in ("roads:Claim(space)", "MapTerrain.PlanRiver(", "MapTerrain.Relief(", "roads:Build(", "buildTown(map")]
if -1 not in _road_gen_order and _road_gen_order != sorted(_road_gen_order):
    problems.append("MapGenerator.Build must claim the roads, plan the river, write the relief, build the roads and then the towns, in that order")

# Hills, landmark terraces, eggs and lakes all write terrain after the relief pass shaped the ground
# under the roads, so the flat corridor is written again once the hills are down and once more after
# the rest.
_road_restores = [m.start() for m in re.finditer(r"MapTerrain\.RestoreRoadGround\(terrain, roads", _road_gen_src)]
_road_writers = [_road_gen_src.find(n) for n in ("MapTerrain.Hills(", "Landmarks.Place(", "EasterEggs.Place(", "MapDecor.Lake(")]
if len(_road_restores) != 2 or -1 in _road_writers or not (
        _road_writers[0] < _road_restores[0] < _road_writers[1] and _road_restores[1] > max(_road_writers[1:])):
    problems.append("MapGenerator must write the road ground again (MapTerrain.RestoreRoadGround) after the hills, and again after the landmarks, eggs and lakes")

# Markings lie on the asphalt, never sunk into it (a sunk marking shares volume with the surface and,
# where the grade changes, overlaps its neighbour).
if re.search(r"MarkSink|MARK_DEPTH", _road_decor_src + _road_roads_src):
    problems.append("road markings must lie on top of the asphalt (MapDecor.MarkRaise only); a sunk marking overlaps the surface")

# The old road builder laid tilted slabs straight onto unshaped ground, with square pads 0.1 under
# the carriageway at crossings. None of it should come back.
for _road_old in ("buildRoad", "JUNCTION_PAD", "JUNCTION_SKIP", "MapDecor.RoadLamps", "segmentCrossing"):
    for _road_rel, _road_text in (("MapGenerator.lua", _road_gen_src), ("MapDecor.lua", _road_decor_src)):
        if _road_old in _road_text:
            problems.append(f"{_road_rel}: old road code `{_road_old}` is back; roads are RoadNetwork's")
print(f"roads: RoadNetwork.Width {_road_road_width.group(1) if _road_road_width else '?'}, {len(_road_lamp_attrs)} signal lamp attributes")

# Remote rate limits (claude-f5, 2026-09-17). Every remote a client can send is either limited by
# RateLimit, wrapped in guard() (which takes from the shared Menu budget), carries its own token
# bucket, or is named in RateLimit.Exempt with a reason. A new unlimited remote fails here.
_rl_src = read("ServerScriptService/Modules/RateLimit.lua")
_rl_exempt = set(re.findall(r"^\t(\w+) = \"", re.search(r"RateLimit\.Exempt = \{(.*?)\n\}", _rl_src, re.S).group(1), re.M))
_rl_budgets = {m.group(1): (float(m.group(2)), float(m.group(3)))
               for m in re.finditer(r"^\t(\w+) = \{ burst = ([\d.]+), rate = ([\d.]+)", _rl_src, re.M)}
if not _rl_budgets: problems.append("RateLimit.Budgets is empty or unreadable")
_rl_handlers = 0
for _rl_rel, _rl_text in lua_files():
    if not _rl_rel.startswith("ServerScriptService"): continue
    for _rl_m in re.finditer(r'(?:Remotes\.(?:Event|Function)\("(\w+)"\)|(\w+))\.(OnServerEvent:Connect|OnServerInvoke)', _rl_text):
        _rl_name = _rl_m.group(1) or _rl_m.group(2)
        _rl_handlers += 1
        if _rl_name in _rl_exempt: continue
        _rl_line = _rl_text[_rl_text.rfind("\n", 0, _rl_m.start()) + 1:_rl_text.find("\n", _rl_m.end())]
        _rl_body = _rl_text[_rl_m.start():_rl_m.start() + 1500]
        if "RateLimit." in _rl_body or "guard(" in _rl_line or "Budget" in _rl_body: continue
        problems.append(f"{_rl_rel}: the {_rl_name} remote has no rate limit and isn't in RateLimit.Exempt")
if _rl_handlers < 20: problems.append(f"rate limits: only {_rl_handlers} client remotes found; the scan looks broken")
# The Fire budget must stay clear of the fastest gun in any pack, or a new gun would be throttled.
_rl_fastest = max([float(m) for _w in ("WeaponData", "ArsenalExpansion", "ArsenalFinish", "CreativeArsenal")
                   for m in re.findall(r"fireRate = ([\d.]+)", read(f"ReplicatedStorage/Shared/{_w}.lua"))] or [0])
_rl_fire = _rl_budgets.get("Fire")
if not _rl_fire or not _rl_budgets.get("RangeFire"): problems.append("rate limits: no Fire/RangeFire budget")
elif _rl_fire[1] < _rl_fastest * 1.25: problems.append(f"rate limits: Fire refills {_rl_fire[1]}/s, under 1.25x the fastest gun's {_rl_fastest}/s")
elif _rl_fire[0] < _rl_fire[1]: problems.append("rate limits: the Fire burst is smaller than its refill rate")
print(f"rate limits: {_rl_handlers} client remotes, {len(_rl_budgets)} budgets, {len(_rl_exempt)} exempt, fastest gun {_rl_fastest}/s vs Fire {_rl_fire[1] if _rl_fire else '?'}/s")

# Town themes (claude-28): every town name MapDecor draws has a theme in TownThemes and a tagline,
# and no theme is named for a town that doesn't exist (a renamed town would silently lose its theme).
_themes_path = "ServerScriptService/Modules/TownThemes.lua"
if os.path.exists(os.path.join(root, _themes_path)):
    _names_block = re.search(r"local TOWN_NAMES = \{(.*?)\n\}", read("ServerScriptService/Modules/MapDecor.lua"), re.S)
    _town_names = set(re.findall(r'"([^"]+)"', _names_block.group(1))) if _names_block else set()
    _tt = read(_themes_path)
    _theme_names = set(re.findall(r'defineTheme\(\{\s*name = "([^"]+)"', _tt))
    _taglines = re.search(r"TownThemes\.Taglines = \{(.*?)\n\}", _tt, re.S)
    _tagged = set(re.findall(r'\["([^"]+)"\] = "', _taglines.group(1))) if _taglines else set()
    if not _town_names:
        problems.append("verify: couldn't read MapDecor's TOWN_NAMES for the town themes check")
    for _n in sorted(_town_names - _theme_names):
        problems.append(f"TownThemes has no theme for town {_n}")
    for _n in sorted(_theme_names - _town_names):
        problems.append(f"TownThemes has a theme for {_n}, which isn't in MapDecor's TOWN_NAMES")
    for _n in sorted(_theme_names - _tagged):
        problems.append(f"TownThemes has no tagline for {_n}")
    print(f"town themes: {len(_theme_names)} themes for {len(_town_names)} town names, {len(_tagged)} taglines")

# Game modes (TDM / King of the Hill). Three of the MatchService seams call into the mode table
# UNCONDITIONALLY — StartWorld on match start, StopWorld on match end, OnRespawn on every respawn —
# while the others guard with `and ... or`. That is safe only because GameMode.BattleRoyale defines
# all three explicitly, two of them as no-ops. A tab tidying away "two functions that do nothing"
# would break match end and respawn with NO static-check warning, because a nil field is not an
# undeclared name. This is the needle that stops that.
#
# Read comment-stripped, so a seam that has been commented out cannot satisfy its own check.
_gm_path = "ServerScriptService/Modules/GameMode.lua"
if os.path.exists(os.path.join(root, _gm_path)):
    _gm = _strip_lua(read(_gm_path))
    _gm_br = re.search(r"GameMode\.BattleRoyale\s*=\s*setmetatable\(\{(.*?)\n\}", _gm, re.S)
    if not _gm_br:
        problems.append("game modes: couldn't find the GameMode.BattleRoyale table")
    else:
        for _gm_fn in ("StartWorld", "StopWorld", "OnRespawn"):
            if not re.search(r"\b%s\s*=" % _gm_fn, _gm_br.group(1)):
                problems.append(f"game modes: GameMode.BattleRoyale has no {_gm_fn}; MatchService calls it "
                                f"unconditionally, so the battle royale would error there")
    _gm_ms = _strip_lua(read("ServerScriptService/Modules/MatchService.lua"))
    _gm_seams = {
        "S7 respawn branch": r"currentMode\.respawn",
        "S8 GameMode.Bind": r"GameMode\.Bind\s*\(",
        "S9 mode resolve": r"GameMode\.Resolve\s*\(",
        "S10 drop select": r"currentMode\.dropSelect",
        "S11 start placement": r"currentMode\.PlaceAtStart",
        "S12 StartWorld": r"currentMode\.StartWorld",
        "S4 StopWorld": r"currentMode\.StopWorld",
        "S13 OnRespawn": r"currentMode\.OnRespawn",
    }
    _gm_missing = [_n for _n, _p in _gm_seams.items() if not re.search(_p, _gm_ms)]
    for _n in _gm_missing:
        problems.append(f"game modes: MatchService seam missing — {_n}")
    # A mode's description must not hard-code a number that disagrees with its own scoreTarget.
    # TeamDeathmatch's said "First to 50 eliminations" while scoreTarget said 100, a few lines apart
    # in the same table, because Oliver's change to 100 never reached the sentence. The descriptions
    # are composed from the target now; this refuses a build where a literal one creeps back in.
    def _gm_no_comments(text):
        # COMMENTS ONLY, NOT STRINGS. verify.py's own _strip_lua replaces every string literal with
        # an empty one, which is right for finding code and fatal here: the thing being checked IS a
        # string. Fed stripped source this check saw an empty description, found no digits in it and
        # passed forever -- and its planted needle still went green, because the needle was handed a
        # raw string while the real input was not. The needle now travels the same pipeline.
        text = re.sub(r"--\[\[.*?\]\]", "", text, flags=re.S)
        return "\n".join(_l for _l in text.split("\n") if not _l.lstrip().startswith("--"))

    def _gm_description_drift(text):
        text = _gm_no_comments(text)
        found = []
        for _m in re.finditer(r"(\w+)\s*=\s*\{(.*?)\n\t\}", text, re.S):
            _name, _body = _m.group(1), _m.group(2)
            _target = re.search(r"scoreTarget\s*=\s*(\d+)", _body)
            _desc = re.search(r'description\s*=\s*"([^"]*)"', _body)
            if not _target or not _desc:
                continue
            for _n in re.findall(r"\b(\d+)\b", _desc.group(1)):
                if _n != _target.group(1):
                    found.append(f"{_name}: description says {_n}, scoreTarget says {_target.group(1)}")
        return found

    for _drift in _gm_description_drift(read("ReplicatedStorage/Shared/GameModes.lua")):
        problems.append(f"game modes: {_drift} — the sentence and the number must not disagree")
    # PERMANENT PLANTED NEEDLE, through the same pipeline as the real input.
    _gm_planted = _gm_description_drift(
        'Broken = {\n\t\tscoreTarget = 100,\n\t\tdescription = "First to 50 eliminations.",\n\t}')
    if not _gm_planted:
        problems.append("game modes: the description-drift check did NOT catch a planted 50-vs-100 "
                        "disagreement — it is testing nothing")
    print(f"game modes: {len(_gm_seams) - len(_gm_missing)}/{len(_gm_seams)} MatchService seams, "
          f"BattleRoyale noops present, {len(_gm_planted)} planted description drift caught")

# A VOTE SNAPSHOT IS NOT AN EVENT (#107, "game choosing menu pulls up randomly mid match").
#
# VoteService.Resolve caches its pick until the next Open(), so from the moment a match starts until
# the next lobby countdown VoteService.Snapshot() reads `open = false` with a `winner` still set --
# and that pair is exactly the cue VoteDropClient reads as "reveal the result". Broadcast is
# FireAllClients, so ONE ungated call (Bootstrap's player-join re-broadcast) popped the mode/map
# reveal onto every player's screen for three seconds every time anybody joined mid-match.
#
# The invariant, which outlives the bug: every VoteService.Broadcast() call OUTSIDE VoteService
# itself must sit inside an `if VoteService.IsOpen() then` guard. Inside VoteService the unguarded
# calls are deliberate -- Open() and Close() are the two transitions that SHOULD reach everyone.
def _vote_broadcast_sites(text):
    # Comment- and string-stripped: this looks for CODE, so the pipeline is right for it. A call
    # sitting in a comment must not satisfy the check, and must not trip it either.
    code = _strip_lua(text)
    examined, ungated = 0, 0
    for _m in re.finditer(r"VoteService\.Broadcast\s*\(", code):
        examined += 1
        before = code[max(0, _m.start() - 160):_m.start()]
        if re.search(r"if\s+VoteService\.IsOpen\s*\(\s*\)\s+then\s*\Z", before):
            continue
        ungated += 1
    return examined, ungated

_vote_callers = []
for _vdir in ("ServerScriptService", "StarterPlayerScripts", "ReplicatedStorage"):
    for _vroot, _, _vfiles in os.walk(os.path.join(root, _vdir)):
        for _vf in _vfiles:
            if not _vf.endswith(".lua") or _vf == "VoteService.lua":
                continue
            _vpath = os.path.relpath(os.path.join(_vroot, _vf), root).replace("\\", "/")
            _vexamined, _vungated = _vote_broadcast_sites(read(_vpath))
            if _vexamined:
                _vote_callers.append((_vpath, _vexamined, _vungated))
            if _vungated:
                problems.append(f"vote rebroadcast: {_vpath} calls VoteService.Broadcast() "
                                f"{_vungated}x without an `if VoteService.IsOpen() then` guard — between a match "
                                f"starting and the next countdown that snapshot still carries a winner, and every "
                                f"client reads it as a fresh reveal (#107)")

# NAME THE INPUT THAT CARRIES THE BUG AND ASSERT IT ENTERED THE COMPARISON. A count of sites alone
# is satisfied by the wrong sites: if Bootstrap's call were renamed or moved out of the walk, this
# whole check would pass by examining nothing.
_vote_bootstrap = [c for c in _vote_callers if c[0].endswith("Bootstrap.server.lua")]
if not _vote_bootstrap:
    problems.append("vote rebroadcast: Bootstrap.server.lua's VoteService.Broadcast() call was not examined "
                    "at all — the check is looking at the wrong files and would pass whatever Bootstrap did")

# PERMANENT PLANTED NEEDLE, through the same pipeline as the real input, and TWO-SIDED: a check that
# flags everything proves as little as one that flags nothing, so the gated call must come back clean
# in the same pass that catches the ungated one.
_vote_needle_examined, _vote_needle_ungated = _vote_broadcast_sites(
    "\tif VoteService.IsOpen() then\n\t\tVoteService.Broadcast()\n\tend\n\tVoteService.Broadcast()\n")
if _vote_needle_examined != 2 or _vote_needle_ungated != 1:
    problems.append(f"vote rebroadcast: the guard check did NOT behave on its planted pair — examined "
                    f"{_vote_needle_examined} (want 2), flagged {_vote_needle_ungated} (want 1: the ungated call "
                    f"caught, the gated one left alone). It is testing nothing.")

print(f"vote rebroadcast: {len(_vote_callers)} file(s) outside VoteService call Broadcast, "
      f"{sum(c[1] for c in _vote_callers)} call site(s) examined, {sum(c[2] for c in _vote_callers)} ungated; "
      f"planted pair {_vote_needle_ungated}/1 caught")

# --- GUNS: #97 hit registration, #106 pickups ----------------------------------
# Four invariants, each with a TWO-SIDED planted needle fed through the same pipeline as the real
# source. Every one is written as "this must never happen" rather than "the bug is still there", so
# landing a fix can never quietly kill its own check.

# COMMENTS ONLY -- NEVER STRINGS, and never the other way round either. _strip_lua above blanks
# string literals, which is right for finding CODE and fatal for reading what a line SAYS. These
# checks must also not be satisfied (or tripped) by the explanatory comments the fixes themselves
# added, which mention IgnoreWater, lastShotAt and Clear by name. Quotes and long brackets are
# tracked so a `--` inside a string survives.
def _guns_decomment(src):
    out, i, n, quote = [], 0, len(src), None
    while i < n:
        c = src[i]
        if quote:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(src[i + 1]); i += 2; continue
            if c == quote:
                quote = None
            i += 1; continue
        if c in "\"'":
            quote = c; out.append(c); i += 1; continue
        if src.startswith("--[[", i):
            j = src.find("]]", i); i = n if j == -1 else j + 2; continue
        if src.startswith("--", i):
            j = src.find("\n", i); i = n if j == -1 else j; continue
        out.append(c); i += 1
    return "".join(out)

# A function body: from its header to the next top-level function in the file. Good enough to keep
# one function's statements away from its neighbours', which is all these checks need.
def _guns_body(src, header):
    i = src.find(header)
    if i == -1:
        return None
    ends = [x for x in (src.find("\nlocal function ", i + len(header)),
                        src.find("\nfunction ", i + len(header))) if x != -1]
    return src[i:min(ends)] if ends else src[i:]

# A DEAD SELF-TEST IS A CHECK PROVING NOTHING, so the summary counts needles that actually fired
# rather than asserting a number. Each needle is derived from the real source (RULE 7: a plant must
# travel the same pipeline as the real input), which means that on genuinely broken source the
# "clean" half is broken too and the pair correctly reports itself degenerate instead of passing.
_gun_needles = 0

_gun_cc = _guns_decomment(read("StarterPlayerScripts/CombatClient.client.lua"))
_gun_cs = _guns_decomment(read("ServerScriptService/Modules/CombatService.lua"))
_gun_rs = _guns_decomment(read("ServerScriptService/Modules/RangeService.lua"))

# INVARIANT 1. Every raycast that decides where a shot goes agrees about terrain water. The client's
# crosshair trace picks the aim POINT and the server fires head->point, so if one stops at water and
# the other passes through it, the shot leaves the crosshair line entirely. They disagreed until
# 2026-09-21 (#97) and a comment in CombatService asserted the opposite, which is why it survived.
def _guns_water(bodies):
    examined, flagged = 0, []
    for label, body in bodies:
        if body is None:
            continue
        examined += 1
        if not re.search(r"^\s*params\.IgnoreWater\s*=\s*true\s*$", body, re.M):
            flagged.append(label)
    return examined, flagged

_gun_water_real = [
    ("CombatClient.crosshairPoint (picks the aim point)", _guns_body(_gun_cc, "local function crosshairPoint()")),
    ("CombatService.buildRaycastParams (fires the shot)", _guns_body(_gun_cs, "local function buildRaycastParams(")),
]
for _label, _body in _gun_water_real:
    if _body is None:
        problems.append(f"guns/water: could not find {_label} — the check is examining nothing")
_gun_water_examined, _gun_water_flagged = _guns_water(_gun_water_real)
for _label in _gun_water_flagged:
    problems.append(f"guns/water (#97): {_label} does not set params.IgnoreWater = true. The aim trace "
                    f"and the shot ray must agree about water or the shot leaves the crosshair line.")

# Two-sided needle: the real pair must come back clean in the same pass that catches a stripped one.
_gun_water_clean = _gun_water_real[0][1] or ""
_gun_water_broken = re.sub(r"^\s*params\.IgnoreWater\s*=\s*true\s*$", "", _gun_water_clean, flags=re.M)
_gw_n, _gw_bad = _guns_water([("planted-broken", _gun_water_broken), ("planted-clean", _gun_water_clean)])
if _gw_n != 2 or _gw_bad != ["planted-broken"]:
    problems.append(f"guns/water (#97): the planted pair did NOT fire — examined {_gw_n} (want 2), "
                    f"flagged {_gw_bad} (want exactly ['planted-broken']). This check is testing nothing.")
else:
    _gun_needles += 1

# INVARIANT 2. The client's shot clock advances by a WHOLE INTERVAL and is never merely reset to the
# current time on a fired shot. tryFire runs on Heartbeat, so resetting quantises the fire rate down
# to the frame rate: 14/s delivered 12.00/s at 60 fps and 10.00/s at 30 fps before this (#97).
def _guns_cadence(body):
    return body is not None and re.search(r"lastLocalShot\s*\+=\s*interval", body) is not None

_gun_tryfire = _guns_body(_gun_cc, "local function tryFire()")
if _gun_tryfire is None:
    problems.append("guns/cadence: could not find CombatClient tryFire — the check is examining nothing")
elif not _guns_cadence(_gun_tryfire):
    problems.append("guns/cadence (#97): tryFire no longer advances lastLocalShot by a whole interval. "
                    "Resetting it to `now` throws the remainder away and quantises every weapon's fire "
                    "rate down to the player's frame rate.")
_gc_broken = re.sub(r"lastLocalShot\s*\+=\s*interval", "lastLocalShot = now", _gun_tryfire or "")
if _guns_cadence(_gc_broken) or not _guns_cadence(_gun_tryfire or ""):
    problems.append("guns/cadence (#97): the planted pair did NOT fire — the reset-only body was accepted "
                    "or the real body was rejected. This check is testing nothing.")
else:
    _gun_needles += 1

# INVARIANT 3. The server never gates shots on a strict inter-shot interval, and there is real slack.
# The client sends on frame boundaries, so consecutive sends are one interval give or take a frame,
# and jitter compresses arrivals further; a strict gate drops those SILENTLY, with the shooter's
# camera already kicked. Both fire paths share ONE budget rather than keeping a copy of the rule.
def _guns_strict_gate(src):
    return [m.group(0).strip() for m in re.finditer(r"[^\n]*lastShotAt\s*<[^\n]*", src)]

_gun_gate_sites = {"CombatService": _guns_strict_gate(_gun_cs), "RangeService": _guns_strict_gate(_gun_rs)}
for _where, _hits in _gun_gate_sites.items():
    for _hit in _hits:
        problems.append(f"guns/rategate (#97): {_where} compares lastShotAt against a threshold "
                        f"(`{_hit}`). Shots are budgeted, not spaced — use CombatService.ShotCredit, "
                        f"or an honest early shot gets dropped with no tracer and no ammo spent.")
_gun_burst = re.search(r"^local FIRE_BURST\s*=\s*(\d+)", _gun_cs, re.M)
if not _gun_burst:
    problems.append("guns/rategate (#97): CombatService has no FIRE_BURST — the shot budget is gone")
elif int(_gun_burst.group(1)) < 2:
    problems.append(f"guns/rategate (#97): FIRE_BURST is {_gun_burst.group(1)}; below 2 there is no slack "
                    f"at all and a shot one frame early is refused.")
if "CombatService.ShotCredit" not in _gun_rs:
    problems.append("guns/rategate (#97): RangeService no longer shares CombatService.ShotCredit. The "
                    "range is where a player learns how a gun feels; a second copy of the rule drifts.")
_gg_broken = "\tif now - loadout.lastShotAt < interval * 0.9 then\n"
if len(_guns_strict_gate(_gg_broken)) != 1 or _guns_strict_gate("\tlocal credit = ShotCredit(loadout)\n"):
    problems.append("guns/rategate (#97): the planted pair did NOT fire — the old strict gate was not "
                    "caught, or the budgeted form was flagged. This check is testing nothing.")
else:
    _gun_needles += 1

# INVARIANT 4. A range stop never destroys a loadout it did not create. WeaponService.Clear sets
# loadouts[player] = nil and GiveWeapon then refuses every pickup with "Not in a match." — a message
# LootService only shows on SUCCESS, so the player saw nothing at all (#106). The guard is an IDENTITY
# check rather than an ordering fix, so it survives the callers being rearranged.
def _guns_stop_guarded(src):
    body = _guns_body(src, "local function stop(player, message)")
    if body is None:
        return None, None
    clears = [m.start() for m in re.finditer(r"WeaponService\.Clear\s*\(", body)]
    guard = body.find("WeaponService.Get(player) == ours")
    return len(clears), (guard != -1 and all(c > guard for c in clears))

_gun_clears, _gun_guarded = _guns_stop_guarded(_gun_rs)
if _gun_clears is None:
    problems.append("guns/rangestop: could not find RangeService stop() — the check is examining nothing")
elif not _gun_guarded:
    problems.append(f"guns/rangestop (#106): RangeService stop() calls WeaponService.Clear ({_gun_clears} "
                    f"site(s)) without first proving the loadout is the one the range created. A stop that "
                    f"lands after MatchService has handed out the match loadout deletes it, and every "
                    f"pickup for the rest of the match is refused silently.")
_grs_broken = _gun_rs.replace("if WeaponService.Get(player) == ours then", "if true then")
_, _grs_bad = _guns_stop_guarded(_grs_broken)
if _grs_bad or not _gun_guarded:
    problems.append("guns/rangestop (#106): the planted pair did NOT fire — an unguarded Clear was accepted, "
                    "or the guarded one was rejected. This check is testing nothing.")
else:
    _gun_needles += 1

print(f"guns: water {_gun_water_examined} shot-raycast site(s) examined, {len(_gun_water_flagged)} "
      f"disagreeing; rate gates {sum(len(v) for v in _gun_gate_sites.values())} strict comparison(s) in 2 "
      f"fire paths, FIRE_BURST {_gun_burst.group(1) if _gun_burst else '?'}; range stop {_gun_clears} "
      f"Clear site(s), guarded {_gun_guarded}; {_gun_needles}/4 planted pairs fired")

# ---------------------------------------------------------------------------
# Companion boons (what a brainrot does FOR its owner) and explosive abilities.
#
# Two ways this data rots silently, which is why it is gated rather than trusted:
#   * a MISSPELLED boon key ("regan") is an error nowhere -- CompanionBoons reads the fields it knows
#     and ignores the rest, so that brainrot simply does nothing and nobody finds out.
#   * a `blast` on a low rarity hands a Common an explosion. The rule is BlastMinRarity, in one place.
_bd = read("ReplicatedStorage/Shared/BrainrotData.lua")
_bv = re.search(r"BrainrotData\.Boons = \{(.*?)\}", _bd, re.S)
_boon_vocab = set(re.findall(r"(\w+) = true", _bv.group(1))) if _bv else set()
_ri = re.search(r"BrainrotData\.RarityIndex = \{(.*?)\}", _bd, re.S)
_rarity_index = dict((m[0], int(m[1])) for m in re.findall(r"(\w+) = (\d+)", _ri.group(1))) if _ri else {}
_mr = re.search(r'BrainrotData\.BlastMinRarity = "(\w+)"', _bd)
_min_rarity = _mr.group(1) if _mr else "Legendary"


def _boon_problems(text):
    """(bad boon keys, blasts below the floor, how many entries carried a boon)."""
    bad_keys, bad_blast, carried = [], [], 0
    floor = _rarity_index.get(_min_rarity, 4)
    for entry in re.finditer(r'\{ name = "([^"]+)", rarity = "(\w+)",([^\n]*)', text):
        name, rarity, rest = entry.group(1), entry.group(2), entry.group(3)
        boon = re.search(r"boon = \{(.*?)\},", rest)
        if boon:
            carried += 1
            for key in re.findall(r"(\w+) =", boon.group(1)):
                if key in ("damage", "duration"):
                    continue
                if key not in _boon_vocab:
                    bad_keys.append("%s: boon key '%s'" % (name, key))
        if re.search(r"\bblast = true", rest) and _rarity_index.get(rarity, 0) < floor:
            bad_blast.append("%s (%s)" % (name, rarity))
    return bad_keys, bad_blast, carried


_bk, _bb, _carried = _boon_problems(_bd)
if not _boon_vocab:
    problems.append("boons: BrainrotData.Boons is missing or empty - the vocabulary check tests nothing")
for _b in _bk:
    problems.append("boons: %s is not in BrainrotData.Boons, so CompanionBoons ignores it and that brainrot silently does nothing" % _b)
for _b in _bb:
    problems.append("boons: %s carries blast = true below BlastMinRarity (%s)" % (_b, _min_rarity))

_pk, _, _ = _boon_problems(_bd.replace("boon = { regen = 0.5 }", "boon = { regan = 0.5 }", 1))
_, _pb, _ = _boon_problems(_bd.replace('{ name = "Trippi Troppi", rarity = "Common",', '{ name = "Trippi Troppi", rarity = "Common", blast = true,', 1))
if not _pk or not _pb:
    problems.append("boons: a planted fault did NOT fire (bad key caught: %s, low-rarity blast caught: %s) - this check is testing nothing" % (bool(_pk), bool(_pb)))

print("boons: %d brainrot(s) carry a boon, vocabulary %d keys, blast floor %s; 2/2 planted faults fired" % (_carried, len(_boon_vocab), _min_rarity))


print("\n".join(problems) if problems else "OK: no problems")
sys.exit(1 if problems else 0)
