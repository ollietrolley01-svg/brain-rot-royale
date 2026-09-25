"""#97, the fire-rate half: how many held-trigger shots the server throws away, before and after.

Runs the REAL fire gates, cut out of the git history, in lupa:
  client  StarterPlayerScripts/CombatClient.client.lua, tryFire: `local now = os.clock()` .. `local target = aimPoint()`
  server  ServerScriptService/Modules/CombatService.lua, Fire:  `local now = os.clock()` .. the line that commits
          the shot (`loadout.lastShotAt = now` before, `CombatService.SpendShot(...)` after), with
          ShotCredit/SpendShot/FIRE_BURST taken from the same revision when it has them.

    python tools/hitreg_firerate_sim.py .            the tables and the checks
    python tools/hitreg_firerate_sim.py . --plant    the planted faults; every one must be caught

Revisions: BEFORE = 741042c (initial commit: client resets to `now`, server drops inside 0.9 x interval),
FIX = 1e964ca (both halves landed in one commit), MAIN = the working tree. Four pairings are run:
before/before, client-fix-only, server-fix-only, main/main.

The model, stated so it can be argued with:
  * a held trigger for SECONDS of client time; the client's Heartbeat runs at `fps` with each frame
    +-FRAME_JITTER of its nominal length (uniform);
  * each send takes NET_BASE plus an exponential jitter with the stated mean; RemoteEvents are reliable
    and ordered, so a packet never arrives before the one sent ahead of it (arrival = max(previous, own));
  * the server runs 60 Hz frames at a random phase and handles every remote that arrived during a frame
    at that frame's start, 20 us apart;
  * the magazine never runs dry (ConsumeAmmo always succeeds), so only the rate gate is measured.
Also printed (not checked): phantom shots at the end of a magazine on main, and the vehicle guns'
client gate (VehicleWeaponClient, modelled by hand and pinned to its source text).

What it does not model: Roblox's own batching of outgoing remotes on the client, server frame drops
under load, packet loss (reliable remotes retransmit, which bunches arrivals: worse than the jitter here).
"""

import os
import re
import subprocess
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("hitreg_firerate_sim: needs lupa (pip install lupa)")

BEFORE, FIX = "741042c", "1e964ca"
CLIENT = "StarterPlayerScripts/CombatClient.client.lua"
SERVER = "ServerScriptService/Modules/CombatService.lua"
VCLIENT = "StarterPlayerScripts/VehicleWeaponClient.client.lua"

SECONDS = 60.0
FRAME_JITTER = 0.10
NET_BASE = 0.050
FPS = (30, 60, 144, 240)
NET_JITTERS = (0.0, 0.005, 0.020)
SEED = 97


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w.\[\]]+) ([+\-*/])= (.+)$", r"\1\2 = \2 \3 \4", source, flags=re.M)


def at(root, rev, path):
    if rev is None:
        return open(os.path.join(root, path), encoding="utf-8").read().replace("\r\n", "\n")
    out = subprocess.run(["git", "-C", root, "show", rev + ":" + path], capture_output=True, text=True, check=True)
    return out.stdout.replace("\r\n", "\n")


def client_block(src):
    """tryFire's rate gate: from the `local now = os.clock()` before the equip-ready test to aimPoint()."""
    anchor = src.index("if now < localEquipReadyAt then")
    start = src.rindex("local now = os.clock()", 0, anchor)
    end = src.index("local target = aimPoint()", anchor)
    return src[start:end]


def server_block(src):
    """Fire's rate gate, and the budget functions it calls if this revision has them."""
    fire = src[src.index("function CombatService.Fire("):]
    fire = fire[: fire.index("\nend\n")]
    start = fire.index("local now = os.clock()")
    if "CombatService.SpendShot(loadout, credit, now)" in fire:
        stop = fire.index("CombatService.SpendShot(loadout, credit, now)")
        stop = fire.index("\n", stop)
        a = src.index("function CombatService.ShotCredit")
        b = src.index("\nend\n", src.index("function CombatService.SpendShot")) + 5
        burst = re.search(r"^local FIRE_BURST = (\d+)", src, re.M).group(1)
        prelude = "local FIRE_BURST = %s\n%s\n" % (burst, src[a:b])
    else:
        stop = fire.index("loadout.lastShotAt = now")
        stop = fire.index("\n", stop)
        prelude = ""
    return prelude, fire[start:stop]


def vehicle_client_line(src):
    """VehicleWeaponClient's gate is inline in a RenderStepped; the sim models it by hand, so check the
    source still says exactly what the model does."""
    want = "if firing and now - lastShotAt >= 1 / spec.fireRate and ready then\n\t\t\tlastShotAt = now"
    return want in src


CLIENT_FACTORY = """
return function()
    local clockNow = 0
    local os = { clock = function() return clockNow end }
    local lastLocalShot = 0
    local localEquipReadyAt = 0
    local function gate(def)
%s
        return true
    end
    return function(def, now) clockNow = now; return gate(def) == true end
end
"""

SERVER_FACTORY = """
return function()
    local clockNow = 0
    local os = { clock = function() return clockNow end }
    local CombatService = {}
%s
    local WeaponService = { ConsumeAmmo = function() return true end }
    local player = {}
    local V = setmetatable({}, { __sub = function() return { Magnitude = 100 } end })
    local character = { FindFirstChild = function() return { Position = V } end, GetPivot = function() return { Position = V } end }
    local aimPoint = V
    local loadout = { lastShotAt = 0 }
    local function gate(def)
%s
        return true
    end
    return function(def, now) clockNow = now; return gate(def) == true end
end
"""

# The vehicle gun's client gate as VehicleWeaponClient:564-565 writes it (reset to `now`).
VEHICLE_CLIENT = """
return function()
    local lastShotAt = 0
    return function(spec, now)
        if now - lastShotAt >= 1 / spec.fireRate then
            lastShotAt = now
            return true
        end
        return false
    end
end
"""

# The main budget as VehicleWeapons.Fire calls it: ShotCredit(state, spec, now) / SpendShot.
VEHICLE_SERVER = """
return function()
    local CombatService = {}
%s
    local state = {}
    return function(spec, now)
        local credit = CombatService.ShotCredit(state, spec, now)
        if credit < 1 then return false end
        CombatService.SpendShot(state, credit, now)
        return true
    end
end
"""

ENGINE = """
local makeClient, makeServer, rate, fps, frameJitter, netBase, netJitter, seconds, seed = ...
math.randomseed(seed)
local client, server = makeClient(), makeServer()
local def = { fireRate = rate }
local start = 0.5 + math.random() * 0.1
local t = start
local sends = {}
local frame = 1 / fps
while t < start + seconds do
    if client(def, t) then sends[#sends + 1] = t end
    t = t + frame * (1 + frameJitter * (2 * math.random() - 1))
end
local SF = 1 / 60
local phase = math.random() * SF
local previous, lastFrame, k, accepted = -1, nil, 0, 0
for _, sent in ipairs(sends) do
    local lat = netBase
    if netJitter > 0 then lat = lat - netJitter * math.log(1 - math.random()) end
    local arrival = math.max(previous, sent + lat)
    previous = arrival
    local f = math.ceil((arrival - phase) / SF)
    if f == lastFrame then k = k + 1 else k = 0; lastFrame = f end
    if server(def, phase + f * SF + k * 2e-5) then accepted = accepted + 1 end
end
return #sends, accepted
"""

# The end of a magazine. The client never counts its own rounds: `slot.mag` changes only when the server's
# loadout push lands (CombatClient:2227; tryFire refuses at `slot.mag <= 0`, :713). The server spends a
# round in ConsumeAmmo and pushes at the end of that frame (WeaponService.PushSoon, task.defer). So for
# about one round trip after the last round, the client keeps sending shots the server refuses for ammo
# (CombatService.Fire: `if not WeaponService.ConsumeAmmo(player) then return end`, no BroadcastShot),
# each one kicked and flashed on the shooter's own screen (addRecoil, kickViewmodel). Counts those.
MAG = """
local makeClient, makeServer, rate, mag, fps, oneWay, netJitter, seed = ...
math.randomseed(seed)
local client, server = makeClient(), makeServer()
local def = { fireRate = rate }
local frame, SF = 1 / fps, 1 / 60
local phase = math.random() * SF
local t = 0.5 + math.random() * 0.1
local serverMag = mag
local pushes = {}          -- { arrival at the client, mag }, in arrival order (reliable, ordered)
local seen, nextPush = mag, 1
local upPrev, downPrev, lastFrame, k = -1, -1, nil, 0
local phantoms = 0
local function jitter() return netJitter > 0 and -netJitter * math.log(1 - math.random()) or 0 end
for _ = 1, 100000 do
    while pushes[nextPush] and pushes[nextPush][1] <= t do seen = pushes[nextPush][2]; nextPush = nextPush + 1 end
    if seen <= 0 or t > 60 then break end
    if client(def, t) then
        local arrival = math.max(upPrev, t + oneWay + jitter())
        upPrev = arrival
        local f = math.ceil((arrival - phase) / SF)
        if f == lastFrame then k = k + 1 else k = 0; lastFrame = f end
        local handled = phase + f * SF + k * 2e-5
        if serverMag <= 0 then
            phantoms = phantoms + 1
        elseif server(def, handled) then
            serverMag = serverMag - 1
            local back = math.max(downPrev, phase + f * SF + SF * 0.5 + oneWay + jitter())
            downPrev = back
            pushes[#pushes + 1] = { back, serverMag }
        end
    end
    t = t + frame * (1 + 0.1 * (2 * math.random() - 1))
end
return phantoms
"""

# A modified client: a send every millisecond for `seconds`, no network. The server must hold it to
# fireRate x seconds plus the burst, whatever the client does.
SPAM = """
local makeServer, rate, seconds = ...
local server = makeServer()
local def = { fireRate = rate }
local accepted = 0
for i = 1, math.floor(seconds * 1000) do
    if server(def, 10 + i / 1000) then accepted = accepted + 1 end
end
return accepted
"""


def load_shared(lua, root, name):
    """ReplicatedStorage/Shared/<name>.lua, with its sibling requires resolved from the same folder."""
    loader = lua.execute("""
      return function(readFile, convert, mocks)
        local cache = {}
        local function load(name)
            if cache[name] then return cache[name] end
            local src = convert(readFile(name))
            local env = setmetatable({}, { __index = _G })
            env.script = { Parent = { WaitForChild = function(_, child) return child end } }
            env.require = load
            env.Vector3, env.CFrame, env.Enum = mocks.Vector3, mocks.CFrame, mocks.Enum
            env.Color3 = { new = function(...) return { ... } end, fromRGB = function(...) return { ... } end }
            env.table = setmetatable({ clone = function(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end }, { __index = table })
            local chunk = assert(_G.load(src, name, "t", env))
            cache[name] = chunk()
            return cache[name]
        end
        return load
      end
    """)
    return loader(lambda n: open(os.path.join(root, "ReplicatedStorage", "Shared", n + ".lua"), encoding="utf-8").read(),
                  luau_to_lua, lua.execute(open(os.path.join(root, "tools", "hitreg_mocks.lua"), encoding="utf-8").read()))(name)


def fire_rates(lua, root):
    weapons = load_shared(lua, root, "WeaponData").Weapons
    by_rate = {}
    for key in weapons:
        by_rate.setdefault(float(weapons[key].fireRate), []).append(key)
        MAGS[key] = (float(weapons[key].fireRate), int(weapons[key].magSize or 1))
    vehicle = load_shared(lua, root, "VehicleWeaponData").Weapons
    vrates = sorted({float(vehicle[k].fireRate) for k in vehicle}, reverse=True)
    return dict(sorted(by_rate.items(), reverse=True)), vrates


class Gates:
    def __init__(self, root, plant_client=None, plant_server=None):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.root = root
        self.sources = {}
        for rev in (BEFORE, FIX, None):
            c = at(root, rev, CLIENT)
            s = at(root, rev, SERVER)
            if rev is None:
                for before, after in plant_client or []:
                    assert before in c, "client plant target missing: " + before
                    c = c.replace(before, after, 1)
                for before, after in plant_server or []:
                    assert before in s, "server plant target missing: " + before
                    s = s.replace(before, after, 1)
            self.sources[rev] = (client_block(c), server_block(s))
        self.engine = self.lua.execute("return function(...) " + ENGINE + " end")
        self.spam = self.lua.execute("return function(...) " + SPAM + " end")
        self.mag = self.lua.execute("return function(...) " + MAG + " end")

    def client(self, rev):
        return self.lua.execute(luau_to_lua(CLIENT_FACTORY % self.sources[rev][0]))

    def server(self, rev):
        prelude, block = self.sources[rev][1]
        return self.lua.execute(luau_to_lua(SERVER_FACTORY % (prelude, block)))

    def run(self, crev, srev, rate, fps, jitter, seconds=SECONDS, seed=SEED):
        return self.engine(self.client(crev), self.server(srev), rate, fps, FRAME_JITTER, NET_BASE, jitter, seconds, seed)

    def vehicle(self, rate, fps, jitter, seconds=SECONDS, seed=SEED):
        prelude, _ = self.sources[None][1]
        server = self.lua.execute(luau_to_lua(VEHICLE_SERVER % prelude))
        return self.engine(self.lua.execute(VEHICLE_CLIENT), server, rate, fps, FRAME_JITTER, NET_BASE, jitter, seconds, seed)


MAGS = {}

PAIRS = [
    ("before", BEFORE, BEFORE),
    ("client fix only", None, BEFORE),
    ("server fix only", BEFORE, None),
    ("main", None, None),
]


def measure(g, rates, jitters=NET_JITTERS, fpss=FPS):
    """{(pair, jitter, fps, rate): (sent, accepted)}"""
    out = {}
    for name, crev, srev in PAIRS:
        for jitter in jitters:
            for fps in fpss:
                for rate in rates:
                    out[(name, jitter, fps, rate)] = g.run(crev, srev, rate, fps, jitter)
    return out


def checks(g, rates, table):
    """The invariants. Each returns (ok, line)."""
    rows = []
    # 1. main keeps every shot a steady client sends, at every frame rate and fire rate, with no jitter
    #    and with typical jitter (5 ms mean).
    for jitter in (0.0, 0.005):
        worst = max(((s - a) / s, fps, rate) for (n, j, fps, rate), (s, a) in table.items() if n == "main" and j == jitter)
        rows.append((worst[0] == 0, "main, net jitter %2d ms: worst drop %.2f%% (at %d fps, %.2f/s)" % (jitter * 1000, worst[0] * 100, worst[1], worst[2])))
    # 2. main delivers each gun's fireRate within 2% at every frame rate (the client no longer quantises).
    worst = max((abs(a / (SECONDS * rate) - 1), fps, rate) for (n, j, fps, rate), (s, a) in table.items() if n == "main" and j == 0.0)
    rows.append((worst[0] < 0.02, "main, delivered rate vs fireRate: worst %.2f%% off (at %d fps, %.2f/s)" % (worst[0] * 100, worst[1], worst[2])))
    # 3. The server holds a 1 kHz spammer to fireRate x seconds + the burst, whatever the client does.
    for rate in (14.0, 4.0, 0.75):
        accepted = g.spam(g.server(None), rate, 10.0)
        cap = rate * 10.0 + 2
        rows.append((accepted <= cap + 1e-9, "server, a 1 kHz spamming client at fireRate %.2f for 10 s: %d accepted (cap %.1f)" % (rate, accepted, cap)))
    # 4. The instrument can see a drop: the pre-fix pair loses shots somewhere.
    lost = sum(s - a for (n, j, fps, rate), (s, a) in table.items() if n == "before")
    rows.append((lost > 0, "control: the pre-fix pair (741042c/741042c) drops %d shots across the grid" % lost))
    # 5. The fix commit and main carry the same gates (so 'after' is 1e964ca's, not something later). The
    #    server block also holds the aim check a later commit moved ahead of ConsumeAmmo; only the budget's
    #    own lines (FIRE_BURST, ShotCredit, SpendShot, and every line that reads the clock or the credit)
    #    are compared.
    def budget_lines(rev):
        prelude, block = g.sources[rev][1]
        return prelude, [l for l in block.splitlines() if "credit" in l or "os.clock" in l]
    same = g.sources[FIX][0] == g.sources[None][0] and budget_lines(FIX) == budget_lines(None)
    rows.append((same, "main's client gate and server budget are byte-identical to 1e964ca's" if same else "main's gates differ from 1e964ca's"))
    return rows


def pct(x):
    return "%5.1f" % (x * 100)


def report(g, by_rate, vrates, table):
    rates = list(by_rate)
    for jitter in NET_JITTERS:
        print("\n== network jitter: exponential, mean %d ms (base %d ms); client frames +-%d%%; %d s held trigger"
              % (jitter * 1000, NET_BASE * 1000, FRAME_JITTER * 100, SECONDS))
        print("   cell = DROPPED %% of shots sent  /  DELIVERED rate vs fireRate %%")
        header = "%-7s %-24s" % ("rate/s", "guns") + "".join("%-26s" % ("%d fps  before | main" % f) for f in FPS)
        print(header)
        for rate in rates:
            names = ",".join(sorted(by_rate[rate]))
            line = "%-7.2f %-24s" % (rate, names[:24])
            for fps in FPS:
                s0, a0 = table[("before", jitter, fps, rate)]
                s1, a1 = table[("main", jitter, fps, rate)]
                line += "%s/%s | %s/%s  " % (pct((s0 - a0) / s0), pct(a0 / (SECONDS * rate) - 1), pct((s1 - a1) / s1), pct(a1 / (SECONDS * rate) - 1))
            print(line)
    print("\n== one fix alone (the masking bug), jitter 5 ms: total shots dropped / sent across all %d fire rates" % len(rates))
    for fps in FPS:
        cells = []
        for name, _, _ in PAIRS:
            s = sum(table[(name, 0.005, fps, r)][0] for r in rates)
            a = sum(table[(name, 0.005, fps, r)][1] for r in rates)
            cells.append("%s %d/%d (%.2f%%)" % (name, s - a, s, 100 * (s - a) / s))
        print("%3d fps: " % fps + " | ".join(cells))
    print("\n== end of a magazine on main, 60 fps, jitter 5 ms: phantom shots per magazine (sent, kicked on the")
    print("   shooter's screen, refused by the server for ammo), mean of 200 magazines, by round trip")
    shown = sorted(MAGS.items(), key=lambda kv: -kv[1][0])
    for key, (rate, mag) in [kv for kv in shown if kv[1][0] >= 4][:12] + [kv for kv in shown if kv[1][0] < 1.5][:2]:
        cells = []
        for rtt in (0.05, 0.10, 0.15):
            total = sum(g.mag(g.client(None), g.server(None), rate, mag, 60, rtt / 2, 0.005, seed) for seed in range(200))
            cells.append("RTT %3d ms: %.2f" % (rtt * 1000, total / 200))
        print("%-22s %5.2f/s mag %3d   %s" % (key, rate, mag, "   ".join(cells)))
    print("\n== vehicle guns on main (client VehicleWeaponClient:564-565 resets to `now`; server ShotCredit)")
    for rate in vrates:
        line = "%-6.2f" % rate
        for fps in FPS:
            s, a = g.vehicle(rate, fps, 0.005)
            line += "  %3d fps: drop %s%%, delivered %s%%" % (fps, pct((s - a) / s), pct(a / (SECONDS * rate) - 1))
        print(line)


PLANTS = [
    # Aimed at invariant 2 (delivered rate): a client that resets to `now` quantises to the frame rate.
    ("client resets to now", [("lastLocalShot += interval\n", "lastLocalShot = now\n")], []),
    # Aimed at invariant 1 (no drops): a budget with no slack is the old strict gate by another name.
    ("server budget with no burst", [], [("local FIRE_BURST = 2", "local FIRE_BURST = 1")]),
    # Aimed at invariant 3 (the cap): a budget that never refuses.
    ("server never refuses", [], [("if credit < 1 then\n\t\treturn\n\tend", "if false then\n\t\treturn\n\tend")]),
    # Aimed at invariant 1 (no drops): a budget refilling slower than fireRate starves an honest client.
    ("server refills 10% slow", [], [("local interval = 1 / def.fireRate\n\tlocal since", "local interval = 1.1 / def.fireRate\n\tlocal since")]),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    probe = LuaRuntime(unpack_returned_tuples=True)
    by_rate, vrates = fire_rates(probe, root)
    if not vehicle_client_line(at(root, None, VCLIENT)):
        sys.exit("hitreg_firerate_sim: VehicleWeaponClient's gate no longer reads as modelled; update VEHICLE_CLIENT")
    rates = list(by_rate)
    if "--plant" in sys.argv:
        caught = 0
        for name, pc, ps in PLANTS:
            g = Gates(root, pc, ps)
            table = measure(g, rates, jitters=(0.0, 0.005), fpss=(60, 144))
            failed = [line for ok, line in checks(g, rates, table)[:5] if not ok]
            print(("CAUGHT  " if failed else "MISSED  ") + name + (("  <- " + failed[0]) if failed else ""))
            caught += bool(failed)
        print("hitreg_firerate_sim plants: %d of %d caught" % (caught, len(PLANTS)))
        sys.exit(0 if caught == len(PLANTS) else 1)
    g = Gates(root)
    table = measure(g, rates)
    report(g, by_rate, vrates, table)
    print()
    rows = checks(g, rates, table)
    for ok, line in rows:
        print(("ok    " if ok else "FAIL  ") + line)
    failed = sum(1 for ok, _ in rows if not ok)
    print("hitreg_firerate_sim: %d checks, %d failed (%d fire rates, %d guns)" % (len(rows), failed, len(rates), sum(len(v) for v in by_rate.values())))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
