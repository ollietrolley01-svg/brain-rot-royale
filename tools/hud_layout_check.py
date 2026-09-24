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
SCENARIOS = [("battle royale", "BattleRoyale", False), ("team match", "TeamDeathmatch", False),
             ("driving", "BattleRoyale", True)]

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
    def __init__(self, root, size, sources, force=None):
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
        for m in MODULES:
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
                local car = W.Instance.new('Model')
                car:SetAttribute('VehicleModel', 'Gunner')
                local seat = W.Instance.new('VehicleSeat')
                seat.Name = 'DriverSeat'
                seat.Parent = car
                local yaw = W.Instance.new('Part')
                yaw.Name = 'TurretYaw'
                yaw.Parent = car
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
            W.fire('LoadoutChanged', { slots = {}, equipped = 1, ammo = {}, maxHealth = 100, health = 100 })
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
        """, mode, driving)

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
            out.append({"site": site, "var": var, "gui": e.gui, "name": e.name,
                        "rect": (round(r.x, 1), round(r.y, 1), round(r.w, 1), round(r.h, 1)), "full": bool(e.full)})
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
                ov = overlap(a["rect"], b["rect"])
                if not ov:
                    continue
                key = frozenset([a["var"], b["var"]])
                if key in ALLOWED:
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
        if scene == "driving":
            guis = {e["gui"] for e in drawn}
            for need in ("VehicleHud", "VehicleWeaponHud"):
                if need not in guis:
                    problems.append(f"[{tag}] driving: nothing of {need} is drawn, so its overlaps are not being measured")
            for e in drawn:
                x, y, ew, eh = e["rect"]
                if x < -0.5 or y < -0.5 or x + ew > w + 0.5 or y + eh > h + 0.5:
                    problems.append(f"[{tag}] driving: {label(e)} {e['rect']} is partly off the screen")

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


# Planted faults, each aimed at an invariant the code must keep forever, not at the bug as it was.
PLANTS = [
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
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    sources = {n: read(root, n) for n in SCRIPTS}
    for m in MODULES:
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
