"""Device compatibility: every player action has a keyboard, a touch and a gamepad path.

    python tools/device_compat_check.py .           the checks
    python tools/device_compat_check.py . --plant   the planted faults; every one must be caught
    python tools/device_compat_check.py . --table   also print the action x device table

Oliver (09-24): "make sure the whole game is phone and xbox compatible". Studio can't prove this -- a
probe can't synthesise input or run a LocalScript -- so, like tools/keybind_check.py (whose Settings
table reader this reuses), it reads the source.

What it checks:
  B  Every input binding in the client (Settings.Bind, ContextActionService:BindAction[AtPriority]) is
     found, and every one is claimed by an action in ACTIONS below. A new binding nobody classified
     fails: the moment to decide its touch and pad paths is when it is added.
  A  Every action in ACTIONS has a path on each device. A path is one of: the binding's own keys
     (a gamepad KeyCode, a touch button), a named anchor in the source that must still be there
     (a HUD button's Activated line), Roblox's own controls, a written waiver, or a known OPEN gap
     with its question for Oliver. A binding that loses its pad key or its touch button fails.
  S  Settings: every action row in Settings.lua is bound somewhere (a row with no binding is a key a
     player can set that does nothing).
  R  Raw input: every InputBegan / InputEnded / JumpRequest / IsKeyDown / IsGamepadButtonDown site in
     the client is counted per file against RAW_SITES, each with what it is for. A new raw key
     handler is where keyboard-only features come from (Ready and the vote keys both are).
  P  ProximityPrompts: no prompt's gamepad key may be a button that is live gameplay where the prompt
     is. Roblox's default is ButtonX, which is Reload in a match and on the range (#86: reloading
     beside a floor gun picked it up). Lobby prompts off the range may keep X; each is listed.
  C  ContextActionService draws at most SEVEN touch buttons (CoreScripts ContextActionTouch.lua:
     `maxButtons = #buttonPositionTable`, 7; slots free on unbind). Buttons bound at load hold their
     slot for good, so every touch button bound later needs a free slot. Over-cap buttons already
     known are OPEN (listed, not failing); a new one fails.
  G  Gamepad entry: every modal screen that takes the cursor gives a pad a selected object
     (`GuiService.SelectedObject = ...`), or is OPEN with its question.

Exit code 1 on any finding.
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import keybind_check  # noqa: E402  (its Settings row reader and path)

CLIENT = "StarterPlayerScripts"
CAS_CAP = 7

# Pad KeyCodes, by name. Anything else under Enum.KeyCode is a keyboard key.
PAD_PREFIXES = ("Button", "DPad", "Thumbstick")


# ---------------------------------------------------------------------------------------------------
# The action table
# ---------------------------------------------------------------------------------------------------

def B(name):
    """The binding called `name` provides this device (derived from its keys and touch flag)."""
    return ("bind", name)


def A(file, needle, what):
    """An anchor: `needle` (plain text) must appear in `file`; `what` says what the path is."""
    return ("anchor", file, needle, what)


def E(what):
    """Roblox's own default controls."""
    return ("engine", what)


def W(why):
    """No path on this device, by design."""
    return ("waived", why)


def OPEN(question):
    """A known gap, reported every run, with the question it waits on."""
    return ("open", question)


HUD = f"{CLIENT}/HudClient.client.lua"
COMBAT = f"{CLIENT}/CombatClient.client.lua"
MENU = f"{CLIENT}/MenuClient.client.lua"

ACTIONS = [
    # (action, keyboard/mouse, touch, gamepad)
    ("Move / look", E("WASD + mouse"), E("thumbstick + drag"), E("sticks")),
    ("Jump / vault / exit a seat", E("Space"), E("jump button"), E("A")),
    ("Fire", B("BRR_Fire"), B("BRR_Fire"), B("BRR_Fire")),
    ("Aim", B("BRR_Aim"), B("BRR_Aim"), B("BRR_Aim")),
    ("Sprint", B("BRR_Sprint"), B("BRR_Sprint"), B("BRR_Sprint")),
    ("Crouch / slide", B("BRR_Crouch"), B("BRR_Crouch"), B("BRR_Crouch")),
    ("Reload", B("BRR_Reload"), B("BRR_Reload"), B("BRR_Reload")),
    ("Companion ability", B("BRR_Companion"), B("BRR_Companion"), B("BRR_Companion")),
    ("Movement item", B("BRR_MovementItem"), B("BRR_MovementItem"), B("BRR_MovementItem")),
    ("First / third person", B("BRR_ToggleCamera"),
     A(COMBAT, "camButton.Activated:Connect(toggleCamera)", "CAM HUD button"), B("BRR_ToggleCamera")),
    ("Zoom step", B("BRR_Zoom"), E("pinch"), W("no free button; T/CAM covers first vs third person")),
    ("Inspect weapon", B("BRR_Inspect"), W("cosmetic"), W("cosmetic; no free button")),
    ("Weapon slot 1-8", B("BRR_Slot*"), A(HUD, "hotbar", "tap a hotbar cell"),
     W("a pad has no number row; Next slot reaches every slot")),
    ("Next slot", B("BRR_NextSlot"), A(HUD, "hotbar", "tap a hotbar cell"), B("BRR_NextSlot")),
    ("Inventory", B("BRR_Inventory"), A(HUD, "tab.Activated:Connect(togglePanel)", "INVENTORY tab"),
     B("BRR_Inventory")),
    ("Menu / shop / trade / crates / settings", B("BRR_Menu"),
     A(MENU, "menuButton.Activated", "SHOP pill"), B("BRR_Menu")),
    ("Menu back / close", B("BrrMenuShellBack"), A(f"{CLIENT}/MenuShell.lua", "self.scrimFrame.Activated:Connect", "tap the scrim or the X"),
     B("BrrMenuShellBack")),
    ("Quests", B("BRR_Quests"), A(MENU, "tracker.Activated:Connect", "quest tracker"), B("BRR_Quests")),
    ("Ready up", A(HUD, 'input.KeyCode == Settings.Key("Ready")', "Ready key"),
     A(HUD, "readyButton.Activated", "READY UP pill"),
     A("ServerScriptService/Modules/LobbyService.lua", "buildReadyPad", "walk onto the airship's ready pad")),
    ("Vote mode & map", A(f"{CLIENT}/VoteDropClient.client.lua", "Enum.KeyCode.One", "1 / 2 / 3"),
     A(f"{CLIENT}/VoteScreen.lua", "button.Activated", "tap a card"),
     OPEN("a pad votes only by selecting a card, and nothing selects one for it: may the vote take the "
          "left stick and A from walking while it is up, or should it get its own buttons?")),
    ("Pick a drop spot", A(f"{CLIENT}/DropPicker.lua", "self:SetPick(wx, wz)", "click the map"),
     A(f"{CLIENT}/DropPicker.lua", "self:SetPick(wx, wz)", "tap the map"),
     OPEN("a pad cannot pick a spot (the map takes MouseButton1/Touch only) and drops at random: a stick "
          "cursor (GamepadService:EnableGamepadCursor), or is random fine on a pad?")),
    ("Pick a team", A(f"{CLIENT}/TeamPickerClient.client.lua", "Enum.KeyCode.One", "1 / 2 / 3"),
     A(f"{CLIENT}/TeamPickerScreen.lua", "Selectable = true", "tap a team"),
     A(f"{CLIENT}/TeamPickerClient.client.lua", "GuiService.SelectedObject = screen:FocusTarget()",
       "selected on open; L1 / R1 / B")),
    ("Spectate next", B("BRR_SpectateNext"), A(COMBAT, 'touchButton("NEXT"', "NEXT button"),
     B("BRR_SpectateNext")),
    ("Leave spectating", B("BRR_SpectateLeave"), A(COMBAT, 'touchButton("LEAVE"', "LEAVE button"),
     B("BRR_SpectateLeave")),
    ("Pick up / open / use a prompt", E("E"), E("tap the prompt"), E("prompt key (see P)")),
    ("Throw (hold to cook)", B("BRR_Throw"), B("BRR_Cook"), B("BRR_Throw")),
    ("Vehicle: drive", E("WASD"), E("thumbstick"), E("R2 / L2 + stick")),
    ("Vehicle: handbrake", B("VehicleHandbrake"), B("VehicleHandbrake"), B("VehicleHandbrake")),
    ("Vehicle gun: fire", B("BRR_VehicleFire"), B("BRR_VehicleFire"), B("BRR_VehicleFire")),
    ("Vehicle gun: aim", B("BRR_GunnerAim"), B("BRR_GunnerAim"), B("BRR_GunnerAim")),
    ("Mounted gun: reload", B("GUNNER_BUTTONS.reload.action"), B("GUNNER_BUTTONS.reload.action"),
     B("GUNNER_BUTTONS.reload.action")),
    ("Mounted gun: leave", E("Space jumps off"), B("GUNNER_BUTTONS.leave.action"),
     B("GUNNER_BUTTONS.leave.action")),
    ("Glider / drop-in steer", E("steers by looking"), E("steers by looking"), E("steers by looking")),
    ("Zipline ride / let go", E("prompt / jump"), E("prompt / jump"), E("prompt / jump")),
    ("Settings sliders", A(MENU, "setFromX(input.Position.X)", "drag"), A(MENU, "setFromX(input.Position.X)", "drag"),
     OPEN("the slider track takes MouseButton1/Touch only, so a pad can reach Settings but not move volume, "
          "FOV or sensitivity; needs a Studio pad test of d-pad input on a selected track before a fix")),
    ("Rebind keys", A(MENU, "listenConnection = UserInputService.InputBegan", "press a key"),
     W("rebinding keyboard keys"), W("rebinding keyboard keys; pad buttons are fixed")),
]

# Binding names that are not player actions of their own.
NOT_ACTIONS = {
    "BrrMenuBack": "MenuClient's name for the menu shell's back binding (same as BrrMenuShellBack)",
}


# ---------------------------------------------------------------------------------------------------
# Raw input sites, per file: how many, and what they are. A changed count fails until this is updated.
# ---------------------------------------------------------------------------------------------------

RAW_SITES = {
    "AdminFly.lua": (7, "admin fly: keyboard only, admins only"),
    "CombatClient.client.lua": (1, "stillHeld: re-reads a held R2/L2"),
    "DropPicker.lua": (1, "click / tap the drop map (see Pick a drop spot)"),
    "HudClient.client.lua": (3, "Ready key; menu/quest key closes the inventory; the legacy drop map"),
    "InventoryPanel.lua": (2, "drag a card (pointer); its drop"),
    "MenuClient.client.lua": (3, "key capture for rebinding; slider drag begin / end"),
    "MovementClient.client.lua": (4, "jump held (Space / A) and JumpRequest for the touch jump"),
    "ProjectileClient.client.lua": (1, "throw still held (mouse / R2)"),
    "TeamPickerClient.client.lua": (1, "1/2/3 and L1/R1/B pick a team"),
    "TouchControls.lua": (2, "its own touch buttons"),
    "UiParts.lua": (1, "touch press colour"),
    "VoteDropClient.client.lua": (1, "1/2/3 vote"),
    "VoteScreen.lua": (1, "touch press colour"),
    "ZiplineClient.client.lua": (1, "JumpRequest lets go"),
}
RAW = re.compile(r"InputBegan:Connect|InputEnded:Connect|JumpRequest:Connect|:IsKeyDown\(|:IsGamepadButtonDown\(")


# ---------------------------------------------------------------------------------------------------
# Prompts that may keep a pad key live elsewhere, and why (Reload is inert where they stand).
# ---------------------------------------------------------------------------------------------------

LIVE_PAD_KEYS = {
    "ButtonX": "Reload", "ButtonY": "Companion", "ButtonA": "Jump", "ButtonR1": "Next slot",
    "ButtonR2": "Fire", "ButtonL2": "Aim", "ButtonL1": "Handbrake", "ButtonL3": "Sprint", "ButtonR3": "Crouch",
    "DPadUp": "Camera", "DPadDown": "Movement item", "DPadLeft": "Quests", "DPadRight": "Inventory",
    "ButtonSelect": "Menu",
}
LOBBY_PROMPTS = {
    # (file, ActionText): why its default ButtonX cannot fire Reload there
    ("EasterEggs.lua", "Inspect"): "lobby easter eggs; Reload needs a match or the range (inCombat)",
    ("LobbyService.lua", "action"): "lobby booths (tabPrompt); off the range",
    ("LobbyService.lua", "Open one"): "crate altar; off the range",
    ("LobbyService.lua", "Spin"): "daily spin; off the range",
    ("LobbyService.lua", "Back to checkpoint"): "Cloud Climb lantern; off the range, no gun there",
}


# ---------------------------------------------------------------------------------------------------
# CAS touch buttons already over the cap (bound while the permanent ones hold every slot).
# ---------------------------------------------------------------------------------------------------

# Empty since the phone HUD polish (2026-09-28): the six that were here (BRAKE, the vehicle gun's FIRE and
# AIM, the mounted gun's RELOAD and LEAVE, COOK) are bound through Settings.BindSeat, which takes the
# on-foot buttons away first (PhoneLayout.TouchSet), so each seat's set is under the cap on its own.
KNOWN_OVER_CAP = set()
OVER_CAP_QUESTION = ("the seven permanent combat buttons fill every ContextActionService slot, so these never "
                     "get a drawn, labelled button on a phone. TouchControls (flag off) was built for this; "
                     "flip it and move these into it, or unbind the on-foot buttons while seated?")

# Modal screens that take the cursor: each must hand a pad a selection.
PAD_ENTRY = {
    f"{CLIENT}/MenuShell.lua": "the menu",
    f"{CLIENT}/InventoryPanel.lua": "the inventory",
    f"{CLIENT}/TeamPickerClient.client.lua": "the team picker",
    f"{CLIENT}/MergeDialog.lua": "the merge dialog",
    f"{CLIENT}/VoteScreen.lua": "the vote (kept across redraws; see Vote mode & map)",
}
PAD_ENTRY_OPEN = {
    f"{CLIENT}/DropPicker.lua": "the drop picker (see Pick a drop spot)",
}


# ---------------------------------------------------------------------------------------------------
# Lua reading
# ---------------------------------------------------------------------------------------------------

OPENERS = {"function", "if", "do", "repeat"}
CLOSERS = {"end", "until"}
WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def call_args(text, start):
    """The arguments of the call whose `(` is at `start`, split at top-level commas. Understands
    strings, comments, brackets and Lua blocks, so an inline handler's commas stay inside it."""
    depth, blocks, i, args, cur = 0, 0, start + 1, [], start + 1
    n = len(text)
    while i < n:
        c = text[i]
        if c in "\"'":
            j = i + 1
            while j < n and text[j] != c:
                j += 2 if text[j] == "\\" else 1
            i = j + 1
            continue
        if text.startswith("--", i):
            if text.startswith("--[[", i):
                j = text.find("]]", i)
            else:
                j = text.find("\n", i)
            i = n if j < 0 else j + 1
            continue
        if c.isalpha() or c == "_":
            m = WORD.match(text, i)
            word = m.group(0)
            if text[i - 1] not in ".:" if i else True:
                if word in OPENERS:
                    blocks += 1
                elif word in CLOSERS:
                    blocks -= 1
            i = m.end()
            continue
        if c in "({[":
            depth += 1
        elif c in ")}]":
            if depth == 0 and blocks == 0:
                args.append(text[cur:i].strip())
                return args, i
            depth -= 1
        elif c == "," and depth == 0 and blocks == 0:
            args.append(text[cur:i].strip())
            cur = i + 1
        i += 1
    raise ValueError("unbalanced call")


def enum_names(arg, prefix):
    return re.findall(prefix + r"\.([A-Za-z0-9]+)", arg)


def resolve_keys(arg, text):
    """`table.unpack(X.name.keys)` -> the `keys = { ... }` of `name = {` in the same file."""
    m = re.match(r"table\.unpack\((?:\w+\.)?(\w+)\.keys\)", arg)
    if m:
        k = re.search(m.group(1) + r" = \{[^\n]*\n[^\n]*keys = \{([^}]*)\}", text)
        return k.group(1) if k else ""
    return arg


def top_level(text, pos):
    """Is `pos` at column 0 (bound at load and never inside a function)?"""
    return pos == 0 or text[pos - 1] == "\n"


def read_bindings(sources):
    """name -> {file, kbm, touch, pad, keys, permanent, sites}"""
    out = {}
    pattern = re.compile(r"(Settings\.BindFixed|Settings\.BindSeat|Settings\.Bind|ContextActionService:BindActionAtPriority"
                         r"|ContextActionService:BindAction)\(")
    for rel, text in sources.items():
        if not rel.startswith(CLIENT) or rel.endswith("Settings.lua"):
            continue
        for m in pattern.finditer(text):
            line_start = text.rfind("\n", 0, m.start()) + 1
            if text[line_start:m.start()].lstrip().startswith("--"):
                continue
            args, _ = call_args(text, m.end() - 1)
            kind = m.group(1)
            name = args[0]
            if kind == "Settings.Bind":
                keys = args[4:]
                touch = len(args) > 3 and args[3] != "nil"
                kbm = True  # the Settings key
            elif kind == "Settings.BindFixed":
                # (name, handler, touch, inputs...): no rebindable key, the touch button as Settings.Bind's.
                keys = args[3:]
                touch = len(args) > 2 and args[2] != "nil"
                kbm = False
            elif kind == "Settings.BindSeat":
                # (name, handler, touch, priority, inputs...): a seat's own action (the phone HUD polish).
                keys = args[4:]
                touch = len(args) > 2 and args[2] != "nil"
                kbm = False
            else:
                touch = args[2] == "true"
                keys = args[4:] if kind.endswith("AtPriority") else args[3:]
                kbm = False
            if name.startswith('"') and name.endswith('"'):
                name = name[1:-1]
            elif name.startswith('"BRR_Slot"'):
                name = "BRR_Slot*"
            elif name == "self.backName":
                name = "BrrMenuShellBack"
            elif re.fullmatch(r"(reload|leave)\.action", name):
                # MountedGunClient's GUNNER_BUTTONS, through its locals.
                name = "GUNNER_BUTTONS." + name
            elif re.fullmatch(r"[A-Z_]+", name):
                const = re.search(r"local " + name + r' = "([^"]+)"', text)
                name = const.group(1) if const else name
            keytext = " ".join(resolve_keys(k, text) for k in keys)
            kc = enum_names(keytext, r"Enum\.KeyCode")
            it = enum_names(keytext, r"Enum\.UserInputType")
            pad = [k for k in kc if k.startswith(PAD_PREFIXES)]
            kbm = kbm or any(not k.startswith(PAD_PREFIXES) for k in kc) or any(t.startswith("Mouse") for t in it)
            touch = touch or "Touch" in it
            entry = out.setdefault(name, {"file": rel, "kbm": False, "touch": False, "pad": [], "sites": 0,
                                          "permanent": False, "casTouch": False})
            entry["kbm"] |= kbm
            entry["touch"] |= touch
            entry["pad"] += [p for p in pad if p not in entry["pad"]]
            entry["sites"] += 1
            entry["permanent"] |= top_level(text, m.start())
            entry["settings"] = kind in ("Settings.Bind", "Settings.BindFixed")
            # Bound through Settings.BindSeat: the on-foot buttons make way for it (PhoneLayout.TouchSet),
            # so it is swapped in, not stacked on top of the seven. tools/touch_seat_check.py runs the swap.
            entry["seat"] = entry.get("seat", False) or kind == "Settings.BindSeat"
            entry["casTouch"] |= touch
    return out


def read_prompts(sources):
    """[(file, ActionText, pad key)] for every ProximityPrompt the server makes."""
    out = []
    for rel, text in sources.items():
        if not rel.startswith("ServerScriptService"):
            continue
        for m in re.finditer(r"local (\w+) = Instance\.new\(\"ProximityPrompt\"\)", text):
            var = m.group(1)
            body = text[m.end():m.end() + 2500]
            stop = re.search(r"\n\t*(local function|function) ", body)
            body = body[:stop.start()] if stop else body
            action = re.search(var + r"\.ActionText = (\"([^\"]*)\"|(\w+))", body)
            label = action.group(2) if action and action.group(2) is not None else (action.group(3) if action else "?")
            key = re.search(var + r"\.GamepadKeyCode = Enum\.KeyCode\.(\w+)", body)
            out.append((Path(rel).name, label, key.group(1) if key else "ButtonX"))
    return out


def load(root):
    sources = {}
    for folder in ("StarterPlayerScripts", "StarterCharacterScripts", "ServerScriptService", "ReplicatedStorage"):
        for path in sorted((Path(root) / folder).rglob("*.lua")):
            sources[path.relative_to(root).as_posix()] = path.read_text(encoding="utf-8")
    return sources


# ---------------------------------------------------------------------------------------------------
# The checks
# ---------------------------------------------------------------------------------------------------

def check(sources, root, verbose=True, table=False):
    problems, notes = [], []
    bindings = read_bindings(sources)

    # C: the seven-slot cap. With TouchControls on, Settings.Bind touch buttons leave CAS.
    tc = sources.get(f"{CLIENT}/TouchControls.lua", "")
    tc_on = re.search(r"^TouchControls\.Enabled = true", tc, re.M) is not None
    def on_cas(name, b):
        return b["casTouch"] and not (tc_on and b.get("settings"))
    permanent = sorted(n for n, b in bindings.items() if b["permanent"] and on_cas(n, b))
    dynamic = sorted(n for n, b in bindings.items() if not b["permanent"] and on_cas(n, b))
    free = CAS_CAP - len(permanent)
    over = set()
    if free < 0:
        problems.append(f"C {len(permanent)} touch buttons bound at load, over the cap of {CAS_CAP}: {', '.join(permanent)}")
    if free <= 0:
        # A seat's own button (Settings.BindSeat) is swapped in for the on-foot ones, not added to them.
        over = set(n for n in dynamic if not bindings[n].get("seat"))
    for name in sorted(over - KNOWN_OVER_CAP):
        problems.append(f"C {name}: a touch button bound after the {len(permanent)} permanent ones, with no slot left")
    for name in sorted(over & KNOWN_OVER_CAP):
        notes.append(f"OPEN C {name}: no ContextActionService slot left on a phone")
    for name in sorted(KNOWN_OVER_CAP - over):
        notes.append(f"STALE C {name}: listed as over the cap but has a slot now; take it off KNOWN_OVER_CAP")

    # B / A: every binding claimed, every action served on every device.
    claimed = set()
    rows = []
    for action, *paths in ACTIONS:
        cells = []
        for device, path in zip(("kbm", "touch", "pad"), paths):
            kind = path[0]
            if kind == "bind":
                name = path[1]
                claimed.add(name)
                b = bindings.get(name)
                if not b:
                    problems.append(f"A {action}: binding {name} not found")
                    cells.append("MISSING")
                    continue
                ok = b["pad"] if device == "pad" else b[device]
                if device == "touch" and ok and name in over:
                    cells.append("OPEN: CAS cap")
                    continue
                if not ok:
                    problems.append(f"A {action}: {name} has no {device} path")
                    cells.append("MISSING")
                else:
                    cells.append("/".join(b["pad"]) if device == "pad" else ("button" if device == "touch" else "key"))
            elif kind == "anchor":
                _, file, needle, what = path
                if needle not in sources.get(file, (Path(root) / file).read_text(encoding="utf-8")
                                             if (Path(root) / file).exists() else ""):
                    problems.append(f"A {action}: the {device} path ({what}) is gone: `{needle}` not in {file}")
                    cells.append("MISSING")
                else:
                    cells.append(what)
            elif kind == "engine":
                cells.append(f"Roblox: {path[1]}")
            elif kind == "waived":
                cells.append(f"none ({path[1]})")
            elif kind == "open":
                cells.append("OPEN")
                notes.append(f"OPEN A {action} on {device}: {path[1]}")
        rows.append((action, cells))
    for name, b in sorted(bindings.items()):
        if name not in claimed and name not in NOT_ACTIONS:
            problems.append(f"B {name} ({b['file']}): a binding no action in ACTIONS claims; say what it is "
                            f"and how touch and pad reach it")

    # S: every Settings action row is bound.
    settings_text = sources.get(keybind_check.SETTINGS.as_posix(), "")
    bound_ids = set()
    for rel, text in sources.items():
        bound_ids |= set(re.findall(r'Settings\.Bind\([^,]+,\s*"(\w+)"', text))
        bound_ids |= set(re.findall(r'Settings\.Key\("(\w+)"\)', text))
    bound_ids |= {f"Slot{i}" for i in range(1, 9)} if "BRR_Slot*" in bindings else set()
    rows_seen = keybind_check.ROW.findall(settings_text)
    for action_id, _ in rows_seen:
        if action_id not in bound_ids:
            problems.append(f"S Settings row {action_id} is bound nowhere: a key a player can set that does nothing")

    # R: raw input sites.
    raw_total = 0
    for rel, text in sorted(sources.items()):
        if not rel.startswith(CLIENT):
            continue
        count = sum(1 for line in text.splitlines() if RAW.search(line) and not line.lstrip().startswith("--"))
        raw_total += count
        name = Path(rel).name
        want = RAW_SITES.get(name, (0, ""))[0]
        if count != want:
            problems.append(f"R {name}: {count} raw input site(s), RAW_SITES says {want}; classify the new one "
                            f"(does it need a touch and a pad path?) and update the count")

    # P: prompts.
    prompts = read_prompts(sources)
    for file, label, key in prompts:
        live = LIVE_PAD_KEYS.get(key)
        if live and (file, label) not in LOBBY_PROMPTS:
            problems.append(f"P {file} prompt '{label}': pad key {key} is {live} where it stands (#86); use ButtonB")

    # G: pad entry for modal screens.
    for file, what in PAD_ENTRY.items():
        text = sources.get(file, "")
        if not re.search(r"GuiService\.SelectedObject = (?!nil)", text):
            problems.append(f"G {what} ({file}) never gives a gamepad a selected object")
    for file, what in PAD_ENTRY_OPEN.items():
        notes.append(f"OPEN G {what}: no gamepad selection")

    if verbose:
        if table:
            print(f"{'action':42} | {'keyboard/mouse':28} | {'touch':28} | gamepad")
            for action, cells in rows:
                print(f"{action[:42]:42} | {cells[0][:28]:28} | {cells[1][:28]:28} | {cells[2]}")
        for note in notes:
            print(note)
        print(f"device_compat_check: {len(bindings)} bindings, {len(ACTIONS)} actions x 3 devices, "
              f"{len(rows_seen)} Settings rows, {raw_total} raw input sites, {len(prompts)} prompts, "
              f"{len(PAD_ENTRY) + len(PAD_ENTRY_OPEN)} modal screens; CAS touch: {len(permanent)} permanent "
              f"+ {len(dynamic)} later, {sum(1 for n in dynamic if bindings[n].get('seat'))} of them swapped in by "
              f"Settings.BindSeat (cap {CAS_CAP}, TouchControls {'on' if tc_on else 'off'})")
        for p in problems:
            print(f"device compat PROBLEM: {p}")
        print(f"problems: {len(problems)}")
    return problems


# ---------------------------------------------------------------------------------------------------
# Planted faults: each edits the source in memory; the check must fail on every one.
# ---------------------------------------------------------------------------------------------------

def plant(sources, file, old, new):
    text = sources[file]
    assert text.count(old) >= 1, f"plant anchor missing in {file}: {old!r}"
    changed = dict(sources)
    changed[file] = text.replace(old, new, 1)
    return changed


PLANTS = [
    ("Reload loses its pad button", COMBAT,
     'position = UDim2.new(1, -140, 1, -280) }, Enum.KeyCode.ButtonX)', 'position = UDim2.new(1, -140, 1, -280) })'),
    ("Sprint loses its touch button", COMBAT,
     'end, { title = "RUN", position = UDim2.new(1, -250, 1, -280) }, Enum.KeyCode.ButtonL3)',
     "end, nil, Enum.KeyCode.ButtonL3)"),
    ("a new keyboard-only action nobody classified", COMBAT,
     "local SLOT_COUNT = 8", 'Settings.Bind("BRR_Dance", "Inspect", function() end)\nlocal SLOT_COUNT = 8'),
    ("a match prompt back on Roblox's default X", "ServerScriptService/Modules/LootService.lua",
     "prompt.GamepadKeyCode = Enum.KeyCode.ButtonB", "-- (planted: default key)"),
    ("the menu no longer selects anything for a pad", f"{CLIENT}/MenuShell.lua",
     "GuiService.SelectedObject = cell", "local _ = cell"),
    ("an eighth touch button bound at load", COMBAT,
     "local SLOT_COUNT = 8",
     'ContextActionService:BindAction("BRR_Emote", function() end, true, Enum.KeyCode.K, Enum.KeyCode.ButtonA)\n'
     "local SLOT_COUNT = 8"),
    # The phone HUD polish: a seat's button bound straight to ContextActionService again is stacked on
    # the seven instead of swapped in for them.
    ("BRAKE bound past the cap again", f"{CLIENT}/VehicleClient.client.lua",
     'Settings.BindSeat("VehicleHandbrake", onHandbrake, { title = "BRAKE", position = UDim2.new(1, -180, 1, -150) },',
     'ContextActionService:BindActionAtPriority("VehicleHandbrake", onHandbrake, true,'),
    ("the inventory's touch tab is gone", HUD, "tab.Activated:Connect(togglePanel)", "-- no tab"),
    ("a new raw key handler", COMBAT,
     "local SLOT_COUNT = 8",
     "UserInputService.InputBegan:Connect(function(i) if i.KeyCode == Enum.KeyCode.K then end end)\n"
     "local SLOT_COUNT = 8"),
    ("a Settings row with no binding", "StarterPlayerScripts/Settings.lua",
     '{ id = "Menu", label = "Open menu", default = "M", group = "General" },',
     '{ id = "Menu", label = "Open menu", default = "M", group = "General" },\n'
     '\t{ id = "Emote", label = "Emote", default = "K", group = "General" },'),
]


def run_plants(sources, root):
    caught = 0
    for label, file, old, new in PLANTS:
        found = check(plant(sources, file, old, new), root, verbose=False)
        ok = len(found) > 0
        caught += ok
        print(f"  plant {'CAUGHT' if ok else 'MISSED'}: {label}" + (f" -> {found[0]}" if ok else ""))
    print(f"device_compat_check --plant: {caught}/{len(PLANTS)} planted faults caught")
    return 0 if caught == len(PLANTS) else 1


def main(argv):
    root = argv[1] if len(argv) > 1 and not argv[1].startswith("--") else "."
    sources = load(root)
    if "--plant" in argv:
        clean = check(sources, root, verbose=False)
        if clean:
            print(f"device_compat_check --plant: the clean tree already fails ({len(clean)}); fix that first")
            return 1
        return run_plants(sources, root)
    return 1 if check(sources, root, table="--table" in argv) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
