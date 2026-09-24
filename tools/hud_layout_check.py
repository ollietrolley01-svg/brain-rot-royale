"""HUD layout check for #80 ("Fix HUD overlap everywhere"), without Studio.

Runs the REAL HUD scripts -- HudClient, ModeScoreHud, BoonHud, VehicleWeaponClient, GunfireCueClient,
with the real PhoneLayout, UiKit, StaminaBar, CompanionAbilityIcon and EventBanner modules -- inside a
mocked Roblox client (tools/hud_mock_world.lua), at desktop, tablet and phone sizes in both
orientations. It then drives a match (MatchChanged, a loadout, a bounty, a speed boost, companion boons,
frames of RenderStepped) and measures where every drawn top-level HUD element actually is.

Why run the scripts rather than transcribe their numbers (tools/hud_overlap_probe.lua's approach): the
bug this was written for is a per-frame `compass.Visible = true` that undid the phone layout's hiding
of it on an upright phone. Only running the per-frame code can see that; a model of where the layout
PUTS things cannot, and the probe reported portrait clean while the compass, the bounty line and the
speed pill were being drawn at their desktop spots over it.

The checks, at every size:
  1. Portrait: no element of the upright HUD is drawn where the DESKTOP HUD would draw it on the same
     screen (each element is matched by the line that created it across two runs of the same viewport,
     one upright and one forced desktop). Screen-centred pieces that are the same in every mode by
     design are listed in SAME_EVERYWHERE, each with its reason.
  2. Portrait: the pieces the upright HUD drops (PhoneLayout's portraitRects has no rect for them) stay
     hidden however many frames and events go by, and come back when the phone turns on its side.
  3. No two drawn HUD rects overlap, except pairs in ALLOWED (intentional stacking, each justified).
  4. Static: every `.Visible =` write on a piece the phone layout can drop goes through hudLayout.show
     (examined count reported).
  5-6. "Is it me?" by UserId; the effects pill (see their comments below).
  7. The player's-eye additions (#86 C14, C37, C39, C40, M4, M13, M32), with the real ItemData,
     WeaponData, Rarity, GameModes and InventoryPanel, at every size: the held item's description and cap
     rule on the desktop hotbar (and nowhere on a phone plate), fitting beside the ammo; the gun's type
     word on the HUD line only when its name lacks it; a tier letter in every filled cell's corner, clear
     of the item name; the bag card's detail on hover (description, or a gun's reach) inside the card,
     above its name; KOTH's per-objective line from the
     server's status string, from MY side, clear of the team tags; the recap's "DOWNED BY X — BACK IN n"
     counting down off RespawnAt (or the recap's own respawnDelay) and gone when it runs out.

    python3 tools/hud_layout_check.py .            the checks
    python3 tools/hud_layout_check.py . --plant    the planted faults; every one must be caught
    python3 tools/hud_layout_check.py . --dump     also print every drawn rect

Needs lupa (`pip install lupa`). Luau's compound assignments are rewritten to plain Lua before loading.
"""

import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("hud_layout_check: needs lupa (pip install lupa)")

SCRIPTS = ["HudClient.client.lua", "ModeScoreHud.client.lua", "BoonHud.client.lua",
           "VehicleWeaponClient.client.lua", "GunfireCueClient.client.lua",
           # The driving HUD: its speed panel, hint and damage line, placed by PhoneLayout on a touch screen.
           "VehicleClient.client.lua"]
MODULES = ["PhoneLayout", "UiKit", "StaminaBar", "CompanionAbilityIcon", "EventBanner"]
# Check 7 only: the bag module, and the shared data modules the words come from. CreativeArsenal is
# stubbed (its rounds pull in Ballistics); its guns are covered by player_eye_check.py "gunword".
EYE_MODULES = ["InventoryPanel"]
EYE_SHARED = ["ItemData", "WeaponData", "ArsenalExpansion", "WorkshopArsenal", "Rarity", "GameModes"]
EYE_STUBS = {"CreativeArsenal": "return { Weapons = {} }",
             # No 3D icons in a mock: the cards and cells fall back to no picture, as when a model fails.
             "ItemModels": "return { Build = function() return nil end }",
             "GunModels": "return { Build = function() return nil end }"}

# (name, width, height, touch). Touch screens have no keyboard, so PhoneLayout.Mode decides from shape.
SIZES = [
    ("desktop 1920x1080", 1920, 1080, False),
    ("desktop 1366x768", 1366, 768, False),
    ("tablet 1024x768", 1024, 768, True),
    ("tablet upright 768x1024", 768, 1024, True),
    ("phone 844x390", 844, 390, True),
    ("phone upright 390x844", 390, 844, True),
    ("small phone upright 375x667", 375, 667, True),
]

# Pieces the upright HUD drops (PhoneLayout.lua's portraitRects: "no compass, no kill feed, no bounty or
# location line, no speed pill"), by the HudClient variable that holds them.
DROPPED_UPRIGHT = ["compass", "bountyLabel", "locationLabel", "feed", "speedPill"]

# Drawn at the same place in every mode, on purpose: they are centred on the crosshair or cover the
# screen, so "desktop position" and "phone position" are the same point. Matched by variable name.
SAME_EVERYWHERE = {
    "crosshair": "the aim point is the screen centre in every mode",
    "hitmarker": "drawn on the crosshair",
    "damageArc": "rings the crosshair",
    "reticle": "the vehicle gun's aim point, the screen centre",
}

# The game states measured at every size.
# "driving" is the driver of an armed car with no gunner's seat (the driver works the gun); "gunner" is
# the passenger in the gunner's seat of an armed car (the gun is theirs, the driving HUD is not). Both
# have a gun in hand, so the HUD's own crosshair would be up if nothing stood it down, and both hear
# gunfire from eight directions, so the cue chevrons are on the ring.
SCENARIOS = [("battle royale", "BattleRoyale", False), ("team match", "TeamDeathmatch", False),
             ("driving", "BattleRoyale", "driver"), ("gunner", "BattleRoyale", "gunner")]

# Screens drawn UNDER the HUD on purpose: an overlap with them is allowed only while their DisplayOrder
# is below the other element's, so the HUD really covers them.
UNDER_LAYERS = {"GunfireCue": "the gunfire chevrons ring the crosshair beneath every panel"}

# Overlaps measured and NOT fixed, listed so the check stays green on everything else and says so every
# run. Not an allow-list: each is a defect with the reason it is still open, and the check fails if one
# of them stops happening (so a fix has to take it off this list). Keys: (size tag, frozenset of vars).
KNOWN_OPEN = {
    ("small phone upright 375x667", frozenset(["weaponFrame", "toast"])):
        "on the shortest upright screens there is no full-width band left for the toast: the hotbar row "
        "sits beside the crosshair and the buttons start under it. The toast is up for about 3 s.",
}

# Pairs allowed to overlap: intentional stacking, each with the reason. Keys are frozensets of variable
# names (or "Gui:Name" for elements another script names).
ALLOWED = {
    frozenset(["crosshair", "hitmarker"]): "the hitmarker is drawn on the crosshair when a shot lands",
}


VEHICLE_MODELS_STUB = """
return setmetatable({ Models = setmetatable({}, { __index = function() return { displayName = 'Patapim Scrambler' } end }) },
    { __index = function() return nil end })
"""

BRAINROT_STUB = """
local B = {}
function B.Get(name) return { name = name, move = 'Slap', rarity = 'Common', color = Color3.new(1, 1, 1) } end
function B.Stats() return { damage = 30, cooldown = 8, health = 120 } end
return setmetatable(B, { __index = function() return function() return nil end end })
"""


def luau_to_lua(source):
    # x += y  ->  x = x + (y)   (the only Luau-only syntax these files use)
    return re.sub(r"^(\s*)([\w.\[\]]+) ([-+*/]|\.\.)= (.+)$", r"\1\2 = \2 \3 (\4)", source, flags=re.M)


def read(root, name):
    return open(os.path.join(root, "StarterPlayerScripts", name), encoding="utf-8").read()


def site_names(sources):
    """Maps "File:line" of a create()/Instance.new() call to the variable it was assigned to."""
    names = {}
    for file, text in sources.items():
        short = file.replace(".lua", "")
        for i, line in enumerate(text.split("\n"), 1):
            m = re.match(r"\s*(?:local\s+)?([\w.]+)\s*=\s*(?:create|Instance\.new|UiKit\.create)\(", line)
            if m:
                names[f"{short}:{i}"] = m.group(1).split(".")[-1]
    return names


class World:
    def __init__(self, root, size, sources, force=None, shared=None, extra_modules=()):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        mock = open(os.path.join(root, "tools", "hud_mock_world.lua"), encoding="utf-8").read()
        self.W = self.lua.execute(mock)
        _, w, h, touch = size
        self.W.install()
        self.W.setup(w, h, touch, not touch)
        for name, text in sources.items():
            self.W.sources[name.replace(".lua", "")] = luau_to_lua(text)
        # A stand-in for ReplicatedStorage's BrainrotData, so the companion tile gets real numbers and its
        # stats line is drawn (the check asserts it is hidden on a touch screen).
        self.W.sources["BrainrotData"] = BRAINROT_STUB
        # The real mounted-weapon table (pure data and maths), and a stand-in for VehicleModels with the
        # longest real vehicle name, so the panels carry the text they carry in the game.
        self.W.sources["VehicleWeaponData"] = luau_to_lua(open(os.path.join(root, "ReplicatedStorage", "Shared",
                                                                            "VehicleWeaponData.lua"), encoding="utf-8").read())
        self.W.sources["VehicleModels"] = VEHICLE_MODELS_STUB
        for name, text in (shared or {}).items():
            self.W.sources[name] = luau_to_lua(text)
        for m in list(MODULES) + list(extra_modules):
            self.W.addModule(m)
        if force:
            # PhoneLayout's own test hook; the module is required from the folder, so set it on the
            # instance every script shares.
            self.lua.execute("local W, f = ... ; local pl = require(W.scriptsFolder:WaitForChild('PhoneLayout')) ; pl.Force = f",
                             self.W, force)
        for s in SCRIPTS:
            self.W.runScript(s.replace(".lua", ""))

    def run(self, code, *args):
        return self.lua.execute("local W = ... ; " + code, self.W, *args)

    def play(self, mode="BattleRoyale", driving=False):
        """A live match: the character spawns, the match starts, a loadout, a companion, a kill, a bounty,
        a boost, boons; in a team mode the scoreline; `driving` puts the player in a gun car's seat."""
        self.run("""
            local mode, driving = select(2, ...)
            if driving then
                -- A Rotster (the roof gun): VehicleWeaponData.ForModel knows it.
                local car = W.Instance.new('Model')
                car:SetAttribute('VehicleModel', 'Rotster')
                local seat = W.Instance.new('VehicleSeat')
                seat.Name = 'DriverSeat'
                seat.Parent = car
                local yaw = W.Instance.new('Part')
                yaw.Name = 'TurretYaw'
                yaw.Parent = car
                if driving == 'gunner' then
                    local gunner = W.Instance.new('Seat')
                    gunner.Name = 'GunnerSeat'
                    gunner.Parent = car
                    seat = gunner
                end
                car.Parent = W.workspace
                W.special(W.character.Humanoid).SeatPart = seat
            end
            W.player.Character = W.character
            W.character.Parent = W.workspace
            local added = rawget(W.player, '__lazy').CharacterAdded
            if added then added:Fire(W.character) end
            local state = { state = 'InProgress', mode = mode, mapRadius = 600, aliveCount = 12, playerCount = 12,
                countdown = 0, minPlayers = 2, mapName = 'Test', teams = mode ~= 'BattleRoyale' }
            W.fire('MatchChanged', state)
            -- A gun in hand, so the HUD's crosshair is wanted.
            W.fire('LoadoutChanged', { slots = { { kind = 'gun', id = 'Rifle', name = 'Rifle', mag = 12, reserve = 60,
                rarity = 'Common' } }, equipped = 1, ammo = {}, maxHealth = 100, health = 100 })
            W.fire('StormChanged', { phase = 1, closing = false, secondsLeft = 60, label = 'Storm closes in', radius = 300,
                center = Vector3.new(0, 0, 0), nextRadius = 200, nextCenter = Vector3.new(0, 0, 0), endsAt = W.now + 60 })
            if mode ~= 'BattleRoyale' then
                W.fire('ModeChanged', { mode = mode, scores = { 3, 1 }, target = 100 })
            end
            W.fire('ProfileChanged', { companion = 'Tralalero Tralala', brainrots = {} })
            -- Three kills inside the rows' six seconds: more than a phone's feed slot holds.
            for i = 1, 3 do
                W.fire('KillFeed', { killer = 'Rival', victim = 'Someone' .. i, method = 'Rifle' })
            end
            W.fire('Bounty', { name = 'Rival', kills = 5, reward = 250 })
            W.player:SetAttribute('SpeedBoostUntil', W.now + 10)
            W.player:SetAttribute('SpeedBoosted', true)
            W.player:SetAttribute('CompanionBoonName', 'Tralalero')
            W.player:SetAttribute('CompanionBoons', 'Faster reload\\nMore ammo')
            W.frame(3)
            if driving then
                -- Gunfire all round: a chevron at eight points of the ring.
                local rival = W.Instance.new('Player')
                for i = 0, 7 do
                    local a = i * math.pi / 4
                    W.fire('ShotFired', rival, Vector3.new(math.sin(a) * 60, 5, 10 - math.cos(a) * 60), {}, 'Common')
                end
                W.frame(1)
            end
        """, mode, driving or False)

    def rotate(self, w, h):
        self.run("local w, h = select(2, ...) ; W.setViewport(w, h) ; W.frame(2)", w, h)

    def drawn(self, names):
        out = []
        items = self.W.drawn()
        for i in range(1, len(items) + 1):
            e = items[i]
            r = e.rect
            site = e.site
            var = names.get(site, e.name)
            parts = []
            if e.parts is not None:
                for j in range(1, len(e.parts) + 1):
                    p = e.parts[j]
                    parts.append((p.x, p.y, p.w, p.h))
            out.append({"site": site, "var": var, "gui": e.gui, "name": e.name, "order": e.order or 0,
                        "rect": (round(r.x, 1), round(r.y, 1), round(r.w, 1), round(r.h, 1)), "full": bool(e.full),
                        "parts": parts or [(r.x, r.y, r.w, r.h)]})
        return out

    def errors(self):
        return list(self.W.errors.values()), list(self.W.warnings.values())

    def visible_var(self, var_site):
        return self.run("""
            local site = select(2, ...)
            for _, inst in ipairs(W.created) do
                if W.instSite(inst) == site then
                    local node, shown = inst, true
                    while node and W.instClass(node) ~= 'ScreenGui' do
                        if not node.Visible then shown = false end
                        node = node.Parent
                    end
                    return shown and W.paints(inst)
                end
            end
            return nil
        """, var_site)


def overlap(a, b):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    w = min(ax + aw, bx + bw) - max(ax, bx)
    h = min(ay + ah, by + bh) - max(ay, by)
    return (w, h) if w > 0.5 and h > 0.5 else None


def label(e):
    return f"{e['var']} ({e['site']})"


def check(root, sources, dump=False, quiet=False):
    names = site_names(sources)
    sites_by_var = {v: k for k, v in names.items() if k.startswith("HudClient.client:")}
    problems = []
    examined_pairs = 0
    examined_elements = 0

    seen_open = set()
    for size, (scene, mode, driving) in [(sz, sc) for sz in SIZES for sc in SCENARIOS]:
        tag, w, h, touch = size
        world = World(root, size, sources)
        world.play(mode, driving)
        errs, warns = world.errors()
        for wmsg in warns:
            if "layout" in wmsg.lower() or "PhoneLayout" in wmsg:
                problems.append(f"[{tag}] layout warning: {wmsg}")
        drawn = world.drawn(names)
        examined_elements += len(drawn)
        if dump:
            print(f"--- {tag}, {scene}: {len(drawn)} drawn")
            for e in drawn:
                print(f"   {label(e):55s} {e['gui']:18s} {e['rect']}")
            for err in errs[:12]:
                print("   error:", err[:220])

        # 3. overlaps
        elems = [e for e in drawn if not e["full"]]
        for i in range(len(elems)):
            for j in range(i + 1, len(elems)):
                a, b = elems[i], elems[j]
                examined_pairs += 1
                ov = None
                for pa in a["parts"]:
                    for pb in b["parts"]:
                        ov = ov or overlap(pa, pb)
                if not ov:
                    continue
                key = frozenset([a["var"], b["var"]])
                if key in ALLOWED:
                    continue
                under = [e for e in (a, b) if e["gui"] in UNDER_LAYERS]
                if len(under) == 1:
                    other = b if under[0] is a else a
                    if under[0]["order"] < other["order"] or (under[0]["order"] < 0 and other["order"] >= 0):
                        continue
                    problems.append(f"[{tag}, {scene}] {label(under[0])} draws OVER {label(other)}: its ScreenGui's "
                                    f"DisplayOrder {under[0]['order']} is not below {other['order']}")
                    continue
                if (tag, key) in KNOWN_OPEN:
                    seen_open.add((tag, key))
                    continue
                problems.append(f"[{tag}, {scene}] overlap {ov[0]:.0f}x{ov[1]:.0f}px: {label(a)} {a['rect']}  /  {label(b)} {b['rect']}")

        # The companion tile's stats line grows leftward from the tile; from the phone slot at the left
        # edge it would run off the screen, so on a touch screen it must be hidden (SetCompact).
        readout = world.run("""
            for _, inst in ipairs(W.created) do
                if inst.Name == 'Readout' and inst.Parent then
                    return inst.Visible
                end
            end
            return 'none'
        """)
        if readout == "none":
            problems.append(f"[{tag}, {scene}] the companion tile's stats line was never made: the check is not exercising it")
        elif touch and readout:
            problems.append(f"[{tag}, {scene}] the companion tile's stats line is shown from the phone slot, off the left edge")
        elif not touch and not readout:
            problems.append(f"[{tag}, {scene}] the companion tile's stats line is hidden on a desktop screen")
        if scene in ("driving", "gunner"):
            # One crosshair: the vehicle gun's own mark, never the hand gun's as well.
            vars_ = {e["var"] for e in drawn}
            if "reticle" not in vars_:
                problems.append(f"[{tag}, {scene}] the vehicle gun's aim mark is not drawn")
            if "crosshair" in vars_:
                problems.append(f"[{tag}, {scene}] two crosshairs: the HUD's is drawn as well as the vehicle gun's")
            if not any(e["gui"] == "GunfireCue" for e in drawn):
                problems.append(f"[{tag}, {scene}] no gunfire chevron is drawn, so their layering is not being checked")
        elif "crosshair" not in {e["var"] for e in drawn}:
            problems.append(f"[{tag}, {scene}] the HUD's crosshair is not drawn with a gun in hand: the one-crosshair check proves nothing")
        if scene in ("driving", "gunner"):
            guis = {e["gui"] for e in drawn}
            for need in (("VehicleHud", "VehicleWeaponHud") if scene == "driving" else ("VehicleWeaponHud",)):
                if need not in guis:
                    problems.append(f"[{tag}] driving: nothing of {need} is drawn, so its overlaps are not being measured")
            for e in drawn:
                x, y, ew, eh = e["rect"]
                if x < -0.5 or y < -0.5 or x + ew > w + 0.5 or y + eh > h + 0.5:
                    problems.append(f"[{tag}] {scene}: {label(e)} {e['rect']} is partly off the screen")

        upright = touch and h > w
        if upright and scene == "battle royale":
            # 2. dropped pieces stay hidden
            for var in DROPPED_UPRIGHT:
                site = sites_by_var.get(var)
                if site and world.visible_var(site):
                    problems.append(f"[{tag}] {var} ({site}) is drawn on an upright phone, which has no place for it")
            # 1. nothing at its desktop spot
            desk = World(root, size, sources, force="desktop")
            desk.play(mode, driving)
            desk_rects = {}
            for e in desk.drawn(names):
                desk_rects.setdefault(e["site"], e["rect"])
            for e in drawn:
                if e["var"] in SAME_EVERYWHERE or e["full"]:
                    continue
                if desk_rects.get(e["site"]) == e["rect"]:
                    problems.append(f"[{tag}] {label(e)} is drawn at its desktop position {e['rect']} on an upright phone")
            # 2b. turning the phone on its side brings them back, and upright again hides them
            world.rotate(h, w)
            for var in ("bountyLabel", "speedPill", "compass"):
                site = sites_by_var.get(var)
                if site and not world.visible_var(site):
                    problems.append(f"[{tag}] {var} did not come back when the phone turned on its side")
            world.rotate(w, h)
            world.run("W.frame(3)")
            for var in DROPPED_UPRIGHT:
                site = sites_by_var.get(var)
                if site and world.visible_var(site):
                    problems.append(f"[{tag}] {var} came back when the phone turned upright again")

    for (tag, key), why in KNOWN_OPEN.items():
        if (tag, key) not in seen_open:
            problems.append(f"known-open overlap {sorted(key)} at {tag} no longer happens: take it off KNOWN_OPEN")
        elif not quiet:
            print(f"OPEN (known, not fixed) [{tag}] {' / '.join(sorted(key))}: {why}")

    # 5. "Is it me?" is asked by UserId (#86 C7): a namesake's bounty is third-person, mine says YOU,
    # and so does the kill-feed highlight.
    world = World(root, SIZES[0], sources)
    world.play()
    me = world.run("""
        local function toastFor(info)
            W.fire('Bounty', info)
            return W.lastToast()
        end
        local out = {}
        out.namesake = toastFor({ name = W.player.DisplayName, userId = 999, kills = 3, reward = 100 })
        out.mine = toastFor({ name = W.player.DisplayName, userId = W.player.UserId, kills = 3, reward = 100 })
        out.bot = toastFor({ name = W.player.DisplayName, kills = 3, reward = 100 })
        return out.namesake .. '|' .. out.mine .. '|' .. out.bot
    """)
    namesake, mine, bot = me.split("|")
    if "YOU" in namesake or "YOU" in bot:
        problems.append(f"a bounty on someone sharing my DisplayName (or a bot) says YOU: {namesake!r} / {bot!r}")
    if "YOU" not in mine:
        problems.append(f"a bounty on me (my UserId) does not say YOU: {mine!r}")

    # 6. The effects pill carries every timed effect at once (#86 C17 boots, C32 protection), and goes
    # away when the last one ends.
    speed_site = sites_by_var.get("speedPill")
    pill = world.run("""
        local site = select(2, ...)
        local pill
        for _, inst in ipairs(W.created) do
            if W.instSite(inst) == site then pill = inst end
        end
        W.player:SetAttribute('BounceBootsUntil', W.now + 12)
        W.character:SetAttribute('SpawnProtected', true)
        W.frame(2)
        local both = pill.Text .. '|' .. tostring(pill.Visible)
        W.player:SetAttribute('SpeedBoosted', nil)
        W.player:SetAttribute('BounceBootsUntil', nil)
        W.character:SetAttribute('SpawnProtected', nil)
        W.frame(2)
        return both .. '|' .. tostring(pill.Visible)
    """, speed_site)
    text, shown, after = pill.split("|")
    for word in ("SPEED BOOST", "BOUNCE BOOTS", "PROTECTED"):
        if word not in text or shown != "true":
            problems.append(f"the effects pill does not show {word} with all three on: {text!r} (shown {shown})")
    if after != "false":
        problems.append("the effects pill stays up after every effect has ended")

    problems += check_player_eye(root, sources, quiet)

    # 4. static: writers of droppable pieces go through the gate
    hud = sources["HudClient.client.lua"]
    start = hud.index("-- Phone and tablet layout (StarterPlayerScripts/PhoneLayout)")
    end = hud.index("PhoneLayout.Reapply = apply", start)
    pieces_block = hud[start:end]
    piece_vars = re.findall(r'\{ key = "\w+", gui = (\w+),', pieces_block)
    writes = 0
    for m in re.finditer(r"^\s*(\w+)\.Visible\s*=", hud, flags=re.M):
        if m.group(1) in piece_vars:
            writes += 1
            if not (start <= m.start() < end):
                line = hud.count("\n", 0, m.start()) + 1
                problems.append(f"HudClient.client.lua:{line}: {m.group(1)}.Visible written directly; a piece the phone "
                                "layout places must be shown through hudLayout.show so the layout can overrule it")
    if not quiet:
        print(f"hud_layout_check: {len(SIZES)} sizes, {examined_elements} drawn elements, {examined_pairs} pairs examined; "
              f"{len(piece_vars)} layout pieces, {writes} direct Visible writes on them found")
    return problems


EYE_LUA = r"""
local W, crossSite = ...
local out = {}
local function find(pred)
    for _, inst in ipairs(W.created) do
        if pred(inst) then return inst end
    end
end
local function all(pred)
    local list = {}
    for _, inst in ipairs(W.created) do
        if pred(inst) then table.insert(list, inst) end
    end
    return list
end
local function rect(inst)
    local r = W.rectOf(inst)
    return r and { r.x, r.y, r.w, r.h } or nil
end
local function shown(inst)
    local node = inst
    while node and W.instClass(node) ~= 'ScreenGui' do
        if not node.Visible then return false end
        node = rawget(node, '__parent')
    end
    return true
end
local Shared = W.game:GetService('ReplicatedStorage'):WaitForChild('Shared')
local ItemData = require(Shared:WaitForChild('ItemData'))
local WeaponData = require(Shared:WaitForChild('WeaponData'))
local Panel = require(W.scriptsFolder:WaitForChild('InventoryPanel'))
local slots = {
    { kind = 'item', id = 'RotBarricade', name = 'Rot Barricade', rarity = 'Rare', itemKind = 'defense', count = 2 },
    { kind = 'weapon', id = 'DoomscrollSMG', name = 'Scrolla Scrolla Brrrap', rarity = 'Uncommon', style = 'smg', mag = 30, magSize = 30, reserve = 90 },
    { kind = 'weapon', id = 'RotSMG', name = 'Rot SMG', rarity = 'Common', style = 'smg', mag = 28, magSize = 28, reserve = 90 },
    false, false, false, false, false,
}
local function loadout(equipped)
    W.fire('LoadoutChanged', { slots = slots, equipped = equipped, ammo = {}, maxHealth = 100, health = 100 })
    W.frame(2)
end

-- C14 / M13: the held item's line.
loadout(1)
local detail = find(function(i) return i.Name == 'ItemDetail' end)
local frame = rawget(detail, '__parent')
local ammo = find(function(i) return rawget(i, '__parent') == frame and W.instClass(i) == 'TextLabel' and i.TextSize == 30 end)
local item = ItemData.Get('RotBarricade')
out.itemWant = item.description .. ' ' .. (item.capRule or '')
out.itemText = detail.Text
out.itemShown = shown(detail) and W.paints(detail)
out.detailRect, out.ammoRect, out.frameRect = rect(detail), rect(ammo), rect(frame)
out.ammoText = ammo.Text
out.detailNatural = 666 + detail.Size.X.Offset  -- the plate's 690 less its 12 px padding each side
-- Every item's text against the box: longest description + cap rule.
local longest = 0
for id, it in pairs(ItemData.Items) do
    local text = (it.description or '') .. ' ' .. (it.capRule or '')
    if #text > longest then longest = #text ; out.longestId = id end
end
out.longest = longest
-- M4: tier letters in the cells.
local tiers = all(function(i) return i.Name == 'Tier' end)
out.tierTexts = {}
out.tierClear = true
for index, t in ipairs(tiers) do
    out.tierTexts[index] = t.Text
    local cell = rawget(t, '__parent')
    for _, sib in ipairs(rawget(cell, '__children')) do
        if W.instClass(sib) == 'TextLabel' and sib ~= t and sib.Text ~= '' then
            local a, b = W.rectOf(t), W.rectOf(sib)
            local w = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
            local h = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
            if t.Text ~= '' and w > 0.5 and h > 0.5 then out.tierClear = false ; out.tierHit = sib.Text end
        end
    end
end
-- C39: the gun lines.
local nameLabel = find(function(i) return rawget(i, '__parent') == frame and W.instClass(i) == 'TextLabel' and i.TextSize == 15 end)
loadout(2)
out.gunLine = nameLabel.Text
out.gunDetailShown = shown(detail) and detail.Text ~= ''
loadout(3)
out.smgLine = nameLabel.Text
out.gunDescribe = Panel.Describe(slots[3])
out.gunRange = WeaponData.Get('RotSMG').range

-- The bag card on hover (C14, C40).
local screen = Instance.new('ScreenGui')
screen.Parent = W.playerGui
local bag = Panel.new(screen, {})
bag:Open({ slots = slots, equipped = 1 })
bag.hovered = 1
bag:_render()
local card = bag.cards[1]
out.cardDetail = card.detail.Text
out.cardDetailShown = card.detail.Visible
out.cardIconHidden = not card.icon.Visible and not card.count.Visible
out.cardRects = { rect(card.card), rect(card.detail), rect(card.name), rect(card.sub) }
bag.hovered = nil
bag:_render()
out.cardAfter = card.detail.Visible


-- C37: objectives, from each side.
W.fire('MatchChanged', { state = 'InProgress', mode = 'KingOfTheHill', teams = true, aliveCount = 8, playerCount = 8 })
loadout(1)
local objectives = find(function(i) return i.Name == 'Objectives' end)
local function koth(team, status)
    W.character:SetAttribute('Team', team)
    W.fire('ModeChanged', { mode = 'KingOfTheHill', scores = { 30, 12 }, target = 250, secondsLeft = 200,
        hillStatus = status, hillHolder = 1 })
    W.frame(1)
    return objectives.Text
end
out.koth1 = koth(1, 'A Ember Squad · B open')
out.koth2 = koth(2, 'A Ember Squad · B open')
out.koth3 = koth(1, 'A Teal Crew · B Ember Squad')
out.kothShown = shown(objectives)
local tags = {}
for _, c in ipairs(rawget(rawget(objectives, '__parent'), '__children')) do
    if W.instClass(c) == 'TextLabel' and c ~= objectives and c.Position.Y.Scale == 1 then table.insert(tags, rect(c)) end
end
out.kothRect, out.tagRects = rect(objectives), tags
W.fire('ModeChanged', { mode = 'KingOfTheHill', scores = { 30, 12 }, target = 250, secondsLeft = 200 })
out.kothNoStatus = objectives.Visible

-- M32: the recap countdown.
W.player:SetAttribute('RespawnAt', W.now + 4.5)
W.fire('DeathRecap', { killer = 'Rival', taken = 60, sources = {} })
W.frame(1)
local title = find(function(i) return W.instClass(i) == 'TextLabel' and type(i.Text) == 'string' and string.find(i.Text, 'RIVAL', 1, true) ~= nil end)
out.recap1 = title and title.Text or ''
W.frame(70)
out.recap2 = title and title.Text or ''
W.frame(300)
out.recap3 = title and title.Text or ''
W.player:SetAttribute('RespawnAt', nil)
W.fire('DeathRecap', { killer = 'Rival', taken = 60, sources = {}, respawnDelay = 3 })
W.frame(1)
out.recap4 = title and title.Text or ''
W.fire('DeathRecap', { taken = 0, sources = {} })
W.frame(1)
out.recap5 = title and title.Text or ''
return out
"""


def check_player_eye(root, sources, quiet=False):
    """Check 7: the #86 player's-eye additions, at every size."""
    problems = []
    shared = {n: open(os.path.join(root, "ReplicatedStorage", "Shared", n + ".lua"), encoding="utf-8").read()
              for n in EYE_SHARED}
    shared.update(EYE_STUBS)
    names = site_names(sources)
    cross_site = next(k for k, v in names.items() if v == "crosshair" and k.startswith("HudClient.client:"))
    for size in SIZES:
        tag, w, h, touch = size
        world = World(root, size, sources, shared=shared, extra_modules=EYE_MODULES)
        world.play()
        try:
            o = world.lua.execute(EYE_LUA, world.W, cross_site)
        except Exception as err:  # a script error is a failed check, not a crash of the checker
            problems.append(f"[{tag}] eye check could not run: {str(err)[:300]}")
            continue
        errs, _ = world.errors()
        for e in errs:
            if "InventoryPanel" in e or "ModeScoreHud" in e or "ItemDetail" in e:
                problems.append(f"[{tag}] script error: {e[:200]}")
        phone = o.detailNatural is None or touch
        # C14 / M13
        if o.itemText != o.itemWant:
            problems.append(f"[{tag}] held item's line is {o.itemText!r}, want its description and cap rule {o.itemWant!r}")
        if touch and o.itemShown:
            problems.append(f"[{tag}] the item description is drawn on the phone hotbar plate, which has no row for it")
        if not touch:
            if not o.itemShown:
                problems.append(f"[{tag}] the held item's description is not drawn on a desktop hotbar")
            d, a, f = list(o.detailRect.values()), list(o.ammoRect.values()), list(o.frameRect.values())
            k = d[2] / o.detailNatural
            ammo_w = len(o.ammoText) * 30 * 0.62 * k
            if d[0] + d[2] > a[0] + a[2] - ammo_w + 0.5 or d[0] < f[0] - 0.5:
                problems.append(f"[{tag}] the item description box {d} runs under the ammo text {o.ammoText!r} ({a})")
            # Two lines of 12 pt Gotham at about 0.55 em a character.
            if o.longest * 12 * 0.55 > 2 * o.detailNatural:
                problems.append(f"[{tag}] {o.longestId}'s description + cap rule ({o.longest} chars) is more than two lines of the box")
        if o.gunDetailShown:
            problems.append(f"[{tag}] a held gun shows an item description line")
        # C39
        if not touch:
            if "· SMG" not in o.gunLine:
                problems.append(f"[{tag}] Scrolla Scrolla Brrrap's HUD line has no type word: {o.gunLine!r}")
            if "· SMG" in o.smgLine:
                problems.append(f"[{tag}] Rot SMG's HUD line repeats its type: {o.smgLine!r}")
        if f"reach {int(o.gunRange)} studs" not in o.gunDescribe:
            problems.append(f"[{tag}] a gun's bag detail does not give its reach ({o.gunRange}): {o.gunDescribe!r}")
        # M4
        tiers = [o.tierTexts[i] for i in range(1, len(o.tierTexts) + 1)]
        if tiers[:3] != ["R", "U", "C"] or any(t for t in tiers[3:]):
            problems.append(f"[{tag}] hotbar tier letters {tiers}, want R U C and blanks for empty slots")
        if not o.tierClear:
            problems.append(f"[{tag}] a hotbar tier letter sits on the cell's {o.tierHit!r} label")
        # The bag card
        if not o.cardDetailShown or o.cardDetail != o.itemWant or not o.cardIconHidden or o.cardAfter:
            problems.append(f"[{tag}] bag card hover detail: shown {o.cardDetailShown}, text {o.cardDetail!r}, "
                            f"picture hidden {o.cardIconHidden}, still up after hover {o.cardAfter}")
        rects = [list(o.cardRects[i].values()) for i in range(1, 5)]
        card, det, nm, sub = rects
        if det[0] < card[0] - 0.5 or det[0] + det[2] > card[0] + card[2] + 0.5 or det[1] < card[1] - 0.5 \
                or det[1] + det[3] > nm[1] + 0.5:
            problems.append(f"[{tag}] bag card detail box {det} is not inside the card {card} above its name {nm}")
        # C37
        strip = lambda s: re.sub(r"<[^>]+>", "", s or "")
        want = [("A YOU  B OPEN", o.koth1), ("A FOE  B OPEN", o.koth2), ("A FOE  B YOU", o.koth3)]
        for good, got in want:
            if strip(got) != good:
                problems.append(f"[{tag}] objectives line {strip(got)!r}, want {good!r}")
        if not o.kothShown or o.kothNoStatus:
            problems.append(f"[{tag}] objectives line shown {o.kothShown} with a status, {o.kothNoStatus} without one")
        kr = list(o.kothRect.values())
        tag_rects = [list(o.tagRects[i].values()) for i in range(1, len(o.tagRects) + 1)]
        if len(tag_rects) != 2:
            problems.append(f"[{tag}] found {len(tag_rects)} team tags beside the objectives line, want 2")
        for tr in tag_rects:
            if overlap(tuple(kr), tuple(tr)):
                problems.append(f"[{tag}] objectives line {kr} overlaps a team tag {tr}")
        if kr[0] < -0.5 or kr[0] + kr[2] > w + 0.5 or kr[1] + kr[3] > h + 0.5:
            problems.append(f"[{tag}] objectives line {kr} is off the screen")
        # M32
        if o.recap1 != "DOWNED BY RIVAL — BACK IN 5" or o.recap2 != "DOWNED BY RIVAL — BACK IN 4":
            problems.append(f"[{tag}] recap countdown reads {o.recap1!r} then {o.recap2!r}, want BACK IN 5 then 4")
        if o.recap3 != "ELIMINATED BY RIVAL":
            problems.append(f"[{tag}] recap after the wait reads {o.recap3!r}, want the plain title back")
        if o.recap4 != "DOWNED BY RIVAL — BACK IN 3":
            problems.append(f"[{tag}] recap with respawnDelay 3 in its payload reads {o.recap4!r}")
        if o.recap5 != "THE STORM GOT YOU":
            problems.append(f"[{tag}] a battle royale storm death's recap reads {o.recap5!r}")
        if phone and not touch:
            problems.append(f"[{tag}] the item description box was never built")
    if not quiet:
        print(f"hud_layout_check: player's-eye additions checked at {len(SIZES)} sizes")
    return problems


# Planted faults, each aimed at an invariant the code must keep forever, not at the bug as it was.
PLANTS = [
    ("the HUD's crosshair staying up while the vehicle gun is yours",
     "HudClient.client.lua", 'and not player:GetAttribute("VehicleGunActive")', ""),
    ("the gunfire chevrons drawn over the HUD",
     "GunfireCueClient.client.lua", "DisplayOrder = -2,", "DisplayOrder = 6,"),
    ("the effects pill forgetting Bounce Boots",
     "HudClient.client.lua", 'table.insert(out, string.format("BOUNCE BOOTS  %ds", math.ceil(boots - now)))', "local _ = boots"),
    ("the bounty toast asking 'is it me?' by name, not UserId",
     "HudClient.client.lua", "if info.userId == nil or info.userId ~= player.UserId then",
     "if info.name ~= player.DisplayName then"),
    ("a per-frame writer that bypasses the layout gate (compass)",
     "HudClient.client.lua", "hudLayout.show(compass, true)", "compass.Visible = true"),
    ("the stamina bar ignoring PhoneLayout's mode",
     "StaminaBar.lua", "local spots = phoneSpots(viewport)", "local spots = nil"),
    ("the layout forgetting what a dropped piece's code last asked for",
     "HudClient.client.lua", "piece.gui.Visible = hudLayout.wanted[piece.gui] == true", "piece.gui.Visible = false"),
    ("the driving HUD keeping its desktop spots on a touch screen",
     "VehicleClient.client.lua", "local spots = PhoneLayout.Active(viewport) and PhoneLayout.Rects(viewport) or nil",
     "local spots = nil"),
    ("the ability tile's stats line ignoring compact mode",
     "CompanionAbilityIcon.lua", "self.readout.Visible = not self.compact", "self.readout.Visible = true"),
    ("an element parked on the minimap",
     "HudClient.client.lua", "-- Phone and tablet layout (StarterPlayerScripts/PhoneLayout)",
     "create('Frame', { Size = UDim2.fromOffset(60, 60), Position = UDim2.new(1, -120, 0, 140), AnchorPoint = Vector2.new(0, 0), Parent = screenGui })\n"
     "-- Phone and tablet layout (StarterPlayerScripts/PhoneLayout)"),
    # Check 7 (#86 player's-eye additions).
    ("the item line dropping the structure cap rule",
     "InventoryPanel.lua", 'text = text .. " " .. item.capRule', "text = text"),
    ("the item description drawn on the phone plate",
     "HudClient.client.lua", 'itemDetail.Visible = itemDetail.Text ~= "" and weaponFrame:GetAttribute("PhoneShape") ~= true',
     'itemDetail.Visible = itemDetail.Text ~= ""'),
    ("the gun type word repeated when the name says it",
     "InventoryPanel.lua", "if string.find(flat, wordFlat, 1, true) or string.find(flat, style, 1, true) then", "if false then"),
    ("the hotbar tier letter dropped",
     "HudClient.client.lua", "refs.tier.Text = (slot and", "refs.tier.Text = '' or (slot and"),
    ("the objectives line ignoring which side I am on",
     "ModeScoreHud.client.lua", 'word = owner == mine and "YOU" or "FOE"', 'word = owner == 1 and "YOU" or "FOE"'),
    ("the recap countdown ignoring RespawnAt",
     "HudClient.client.lua", 'local at = recap.backAt or player:GetAttribute("RespawnAt")', "local at = recap.backAt"),
    ("the bag card's gun detail without its reach",
     "InventoryPanel.lua", 'table.insert(parts, string.format("reach %d studs", def.range))', "local _ = parts"),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    sources = {n: read(root, n) for n in SCRIPTS}
    for m in MODULES + EYE_MODULES:
        sources[m + ".lua"] = read(root, m + ".lua")
    if "--plant" in sys.argv:
        missed = 0
        for what, file, anchor, replacement in PLANTS:
            if anchor not in sources[file]:
                print(f"PLANT ANCHOR MISSING ({what}): {anchor!r} not in {file} -- update the plant")
                missed += 1
                continue
            mutated = dict(sources)
            mutated[file] = sources[file].replace(anchor, replacement, 1)
            problems = check(root, mutated, quiet=True)
            print(f"plant: {what}: {'CAUGHT' if problems else 'MISSED'} ({len(problems)} problems)")
            for p in problems[:3]:
                print("   ", p)
            missed += 0 if problems else 1
        print("plants missed:", missed)
        sys.exit(1 if missed else 0)
    problems = check(root, sources, dump="--dump" in sys.argv)
    for p in problems:
        print("PROBLEM", p)
    print(f"problems: {len(problems)}")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
