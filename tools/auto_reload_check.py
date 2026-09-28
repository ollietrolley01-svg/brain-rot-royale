"""Auto-reload asks on the server's round count, never the client's: the false-empty reload finding.

The finding (lag/bug sweep, read-only review of pc/hitreg-fixes b254eac, CombatClient:755): tryFire asked for an
auto-reload whenever its own round count (roundsInHand) read empty. A shot the server refuses before
ConsumeAmmo (the shot budget, the aim check) sends no loadout push, so that count reads empty for a round trip
with rounds still in the magazine, and WeaponService.Reload refuses only a FULL magazine: the ask started a full
reload for nothing. dd6cfb0 gates the ask on the server's `slot.mag`; it reached main in 3c0a18a, and f98a0a5
moved its clocks to tick(). This check measures that behaviour instead of reading the source order.

Runs the REAL client code in lupa, cut from StarterPlayerScripts/CombatClient.client.lua: everything from
`local autoReloadAskedAt = 0` to the end of tryFire (roundTrip, roundsInHand, drivingVehicle, tryFire), plus the
two lines of the loadoutChanged handler that take a push (`loadout = newLoadout`, `loadoutPushedAt = tick()`).
The trigger is held and tryFire runs once a Heartbeat, as the fire binding does.

    python tools/auto_reload_check.py .            the measurements and the checks
    python tools/auto_reload_check.py . --plant    the planted faults; every one must be caught
    python tools/auto_reload_check.py . --client-rev b254eac    the same checks on another revision's client
                                                   (b254eac, before dd6cfb0, is the control: I1 must fail there)

The server is modelled by hand, pinned to its source text (the run stops if the pinned lines change):
  * a shot arrives rtt/2 (+ jitter) after it is sent; a refused one (probability `refuse`, standing for the
    budget and aim checks ahead of ConsumeAmmo) changes nothing and sends nothing; an accepted one spends a
    round if the magazine has one and is not reloading, and pushes the loadout;
  * a reload ask is ignored while reloading or on a full magazine (WeaponService.Reload), otherwise it starts a
    reload, pushes, and pushes a full magazine reloadTime later;
  * every push reaches the client rtt/2 (+ jitter) later; both directions are reliable and ordered.
GetNetworkPing is read both as the whole round trip and as half of it, because roundsInHand treats it as the
round trip and nothing here measures which one Roblox returns. RateLimit's Reload bucket (4/s, burst 5) is not
modelled: one ask per 0.6 s never reaches it (pinned).

Candidates: every gun in WeaponData (65 on main), each with its own fireRate, magSize and reloadTime, run at
four round trips, two ping readings, four frame rates and five refusal rates, plus a deaf-server grid and an
AutoReload-off grid. Every run starts with at most 3 rounds, so each run empties and reloads a magazine.

The invariants (each one has a plant aimed at it):
  I1  no reload ask ever reaches the server while its magazine holds a round (no false-empty reload);
  I2  a truly empty magazine with AutoReload on and the trigger held is reloaded, by exactly one ask
      (round trips under the 0.6 s window);
  I3  asks are at least 0.6 s apart, and against a server that never answers, one comes in every window;
  I4  with AutoReload off, nothing asks;
  I5  the local count recovers: with every shot refused, the gun sends again within the round-trip age.
Printed, not checked: the same held trigger at a real round trip of 0.8 s (past the 0.5 s ping clamp and the
0.6 s window), where a second ask lands while the server is already reloading and is ignored.

What it does not model: CombatService's real refusal reasons and timings (a refusal is a coin flip here),
Roblox's batching of remotes, packet loss, a weapon swap or a pickup mid-run, the dry-fire click (the
BRR_Fire binding, pinned statically by hitreg_rewind_check), and anything a player sees or hears.
"""

import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("auto_reload_check: needs lupa (pip install lupa)")

from hitreg_firerate_sim import load_shared, luau_to_lua  # noqa: E402

CLIENT = "StarterPlayerScripts/CombatClient.client.lua"
WEAPONS = "ServerScriptService/Modules/WeaponService.lua"
BOOT = "ServerScriptService/Bootstrap.server.lua"
RATELIMIT = "ServerScriptService/Modules/RateLimit.lua"

RTTS = (0.03, 0.1, 0.25, 0.5)
PING_READS = (1.0, 0.5)   # GetNetworkPing as the whole round trip, and as half of it
FPS = (30, 60, 144, 240)
REFUSE = (0.0, 0.3, 0.5, 0.8, 1.0)
FRAME_JITTER = 0.10
NET_JITTER = 0.005        # mean of the exponential jitter on each leg
WINDOW = 0.6              # tryFire's retry window
FLIGHT_MARGIN = 0.1       # roundsInHand's FLIGHT_MARGIN (pinned below)
START_MAG = 3
SEED = 755

# Pinned server and client text: the model above is only as good as these lines.
PINS = [
    (WEAPONS, "if not loadout or not def or loadout.reloading then", "Reload refuses while reloading"),
    (WEAPONS, "if slot.mag >= def.magSize then", "Reload refuses only a full magazine"),
    (WEAPONS, "if not loadout or not slot or slot.mag <= 0 then\n\t\treturn false\n\tend\n\tslot.mag -= 1\n\tWeaponService.PushSoon(player)",
     "ConsumeAmmo spends a round and pushes; an empty magazine refuses without a push"),
    (BOOT, 'if not RateLimit.Take(player, "Reload") then', "the reload remote takes a RateLimit token"),
    (RATELIMIT, "Reload = { burst = 5, rate = 4,", "Reload's bucket is 4/s, burst 5 (one ask per 0.6 s never reaches it)"),
    (CLIENT, "local FLIGHT_MARGIN = 0.1", "roundsInHand ages a shot out after the round trip + 0.1 s"),
]

ENGINE = r"""
return function(chunkSrc, gun, rtt, pingRead, fps, refuse, autoReload, deaf, magStart, T, seed)
    math.randomseed(seed)
    local now = 1000.0
    local function jitter(mean) return -mean * math.log(1 - math.random()) end

    local env = setmetatable({}, { __index = _G })
    env.tick = function() return now end
    env.os = setmetatable({ clock = function() return now end }, { __index = os })
    env.math = setmetatable({ clamp = function(x, a, b) return math.max(a, math.min(b, x)) end }, { __index = math })
    env.player = { Character = nil, GetNetworkPing = function() return pingRead end }
    env.Settings = { Get = function(key) if key == "AutoReload" then return autoReload end end }
    env.inCombat = function() return true end
    env.equippedDef = function()
        local l = env.loadout
        return l and l.slots[l.equipped] and gun or nil
    end
    env.aimPoint = function() return true end
    env.addRecoil = function() end
    env.kickViewmodel = function() end
    env.localEquipReadyAt, env.lastLocalShot, env.rangeActive = 0, 0, false

    -- The network: two reliable, ordered legs.
    local toServer, toClient = {}, {}
    local lastUp, lastDown = 0, 0
    local function up(kind)
        lastUp = math.max(lastUp, now + rtt / 2 + jitter(NET_JITTER))
        toServer[#toServer + 1] = { at = lastUp, kind = kind }
    end

    local r = { asks = {}, sends = {}, falseAsks = 0, dupAsks = 0, wasted = 0, reloads = 0, episodes = 0,
                missed = 0, refillAt = nil, sendsAfterRefill = 0, maxEpisodeAsks = 0 }
    env.reloadRemote = { FireServer = function() r.asks[#r.asks + 1] = now; up("reload") end }
    env.fireRemote = { FireServer = function() r.sends[#r.sends + 1] = now; up("fire") end }
    env.rangeFireRemote = env.fireRemote

    -- The server's loadout, and the snapshot it pushes.
    local srv = { mag = magStart, reloading = false, doneAt = nil }
    local function snapshot()
        return { equipped = 1, reloading = srv.reloading, slots = { { kind = "weapon", id = "G", mag = srv.mag } } }
    end
    local function push(t)
        lastDown = math.max(lastDown, t + rtt / 2 + jitter(NET_JITTER))
        toClient[#toClient + 1] = { at = lastDown, snap = snapshot(), refill = srv.mag == gun.magSize and not srv.reloading }
    end
    local episode = (magStart <= 0) and { start = now, asks = 0 } or nil
    if episode then r.episodes = r.episodes + 1 end

    local client = assert(load(chunkSrc, "CombatClient", "t", env))()
    client.push(snapshot())

    local function serverMessage(m)
        if m.kind == "fire" then
            if math.random() < refuse then return end         -- budget / aim check: no ammo spent, no push
            if srv.reloading or srv.mag <= 0 then return end   -- ConsumeAmmo refuses, no push
            srv.mag = srv.mag - 1
            push(m.at)
            if srv.mag <= 0 then
                episode = { start = m.at, asks = 0 }
                r.episodes = r.episodes + 1
            end
        else
            if srv.reloading then r.dupAsks = r.dupAsks + 1 return end
            if srv.mag > 0 then r.falseAsks = r.falseAsks + 1 end
            if deaf then
                if episode then episode.asks = episode.asks + 1 end
                return
            end
            if srv.mag >= gun.magSize then return end
            if srv.mag > 0 then r.wasted = r.wasted + 1 end
            if episode then
                episode.asks = episode.asks + 1
                r.maxEpisodeAsks = math.max(r.maxEpisodeAsks, episode.asks)
                episode = nil
            end
            srv.reloading = true
            srv.doneAt = m.at + gun.reloadTime
            r.reloads = r.reloads + 1
            push(m.at)
        end
    end

    -- Everything due by `now`, earliest first.
    local function settle()
        while true do
            local best, which = math.huge, nil
            if toServer[1] and toServer[1].at < best then best, which = toServer[1].at, "s" end
            if toClient[1] and toClient[1].at < best then best, which = toClient[1].at, "c" end
            if srv.doneAt and srv.doneAt < best then best, which = srv.doneAt, "d" end
            if not which or best > now then return end
            if which == "s" then
                serverMessage(table.remove(toServer, 1))
            elseif which == "c" then
                local p = table.remove(toClient, 1)
                local saved = now
                now = p.at
                client.push(p.snap)
                now = saved
                if p.refill and not r.refillAt then r.refillAt = p.at end
            else
                srv.mag, srv.reloading, srv.doneAt = gun.magSize, false, nil
                push(best)
            end
        end
    end

    local stop = now + T
    local dt = 1 / fps
    r.maxFrame = 0
    while now < stop do
        local frame = dt * (1 + (math.random() * 2 - 1) * FRAME_JITTER)
        r.maxFrame = math.max(r.maxFrame, frame)
        now = now + frame
        settle()
        local before = #r.sends
        client.tryFire()
        if r.refillAt and #r.sends > before then r.sendsAfterRefill = r.sendsAfterRefill + 1 end
    end
    if episode and not deaf and autoReload and now - episode.start > rtt + 0.2 then r.missed = r.missed + 1 end
    r.stop = stop
    r.maxEpisodeAsks = math.max(r.maxEpisodeAsks, episode and episode.asks or 0)
    return r
end
"""


def read(root, path):
    return open(os.path.join(root, path), encoding="utf-8").read().replace("\r\n", "\n")


def client_chunk(src):
    """The real client code under test, as a chunk returning tryFire and the push handler's two lines."""
    start = src.index("local autoReloadAskedAt = 0")
    body = src.index("local function tryFire()", start)
    end = src.index("\nend\n", body) + len("\nend\n")
    handler = src.index("loadoutChanged.OnClientEvent:Connect(function(newLoadout)")
    take = src.index("loadout = newLoadout\n\tloadoutPushedAt = ", handler)  # tick() on main, os.clock() before f98a0a5
    take_end = src.index("\n", src.index("loadoutPushedAt = ", take))
    pushed = src[take:take_end]
    return luau_to_lua(src[start:end] + "\nlocal function __push(newLoadout)\n\t" + pushed + "\nend\n"
                       + "return { tryFire = tryFire, push = __push, roundsInHand = roundsInHand }\n")


def guns(lua, root):
    weapons = load_shared(lua, root, "WeaponData").Weapons
    out = []
    for key in sorted(weapons):
        w = weapons[key]
        out.append((key, lua.table_from({"fireRate": float(w.fireRate), "magSize": int(w.magSize or 1),
                                         "reloadTime": float(w.reloadTime or 0)})))
    return out


def run_all(root, src):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().NET_JITTER = NET_JITTER
    lua.globals().FRAME_JITTER = FRAME_JITTER
    engine = lua.execute(ENGINE)
    chunk = client_chunk(src)
    arsenal = guns(lua, root)
    seed = [SEED]

    def go(gun, rtt, read_, fps, refuse, auto, deaf, mag, T):
        seed[0] += 1
        return engine(chunk, gun, rtt, rtt * read_, fps, refuse, auto, deaf, mag, T, seed[0])

    m = {"guns": len(arsenal), "held": 0, "false": 0, "wasted": 0, "dup": 0, "missed": 0, "episodes": 0,
         "reloads": 0, "one_ask": 0, "close": 0, "min_gap": 1e9, "stuck": 0, "worst_gap_over": -1e9,
         "no_resume": 0, "resumable": 0, "deaf": 0, "deaf_bad": 0, "deaf_asks": 0, "off": 0, "off_asks": 0,
         "slow_dup": 0, "slow_runs": 0, "slow_false": 0, "examples": []}

    def gaps(asks):
        return [asks[i + 1] - asks[i] for i in range(len(asks) - 1)]

    for name, gun in arsenal:
        interval = 1 / gun.fireRate
        mag = min(START_MAG, gun.magSize)
        for rtt in RTTS:
            for read_ in PING_READS:
                rttc = min(0.5, max(0.03, rtt * read_))
                for fps in FPS:
                    for refuse in REFUSE:
                        if refuse < 1:
                            T = min(40.0, mag / (gun.fireRate * (1 - refuse)) + gun.reloadTime + rtt + 1.5 + 2 * interval)
                        else:
                            T = 4.0
                        r = go(gun, rtt, read_, fps, refuse, True, False, mag, T)
                        m["held"] += 1
                        asks = list(r.asks.values())
                        sends = list(r.sends.values())
                        m["false"] += r.falseAsks
                        m["wasted"] += r.wasted
                        m["dup"] += r.dupAsks
                        m["missed"] += r.missed
                        m["episodes"] += r.episodes
                        m["reloads"] += r.reloads
                        if r.maxEpisodeAsks > 1:
                            m["one_ask"] += 1
                        g = gaps(asks)
                        if g:
                            m["min_gap"] = min(m["min_gap"], min(g))
                            if min(g) <= WINDOW:
                                m["close"] += 1
                        if (r.falseAsks or r.dupAsks or r.missed) and len(m["examples"]) < 3:
                            m["examples"].append("%s rtt %.2f ping x%.1f %d fps refuse %.1f: %d false, %d dup, %d missed"
                                                 % (name, rtt, read_, fps, refuse, r.falseAsks, r.dupAsks, r.missed))
                        if refuse == 1.0:
                            # I5: every shot refused, the magazine never empties; the gun keeps sending. The
                            # silence after the last send counts too: a gun that goes quiet for good has no gap.
                            bound = max(interval, rttc + FLIGHT_MARGIN) + 2 * r.maxFrame + 1e-6
                            worst = max(gaps(sends + [r.stop])) if sends else T
                            m["worst_gap_over"] = max(m["worst_gap_over"], worst - bound)
                            if worst > bound or len(sends) < 2:
                                m["stuck"] += 1
                        elif r.refillAt and r.stop - r.refillAt > interval + 3 / fps + 0.05:
                            m["resumable"] += 1
                            if r.sendsAfterRefill == 0:
                                m["no_resume"] += 1

        # I3: a truly empty gun and a server that never answers: one ask per window, never closer.
        for rtt in RTTS:
            for fps in FPS:
                T = 3.1
                r = go(gun, rtt, 1.0, fps, 0.0, True, True, 0, T)
                m["deaf"] += 1
                asks = list(r.asks.values())
                g = gaps(asks)
                bad = not asks or any(x <= WINDOW or x > WINDOW + r.maxFrame + 1e-6 for x in g) \
                    or len(asks) < int(T // (WINDOW + r.maxFrame))
                m["deaf_asks"] += len(asks)
                if bad:
                    m["deaf_bad"] += 1
        # I4: AutoReload off: nothing asks, empty or refused.
        for rtt in RTTS:
            for mag0, refuse in ((0, 0.0), (mag, 1.0), (mag, 0.0)):
                r = go(gun, rtt, 1.0, 60, refuse, False, False, mag0, 3.0)
                m["off"] += 1
                m["off_asks"] += len(r.asks)
        # Printed, not checked: a real round trip past the ping clamp and the window.
        r = go(gun, 0.8, 1.0, 60, 0.0, True, False, mag, mag / gun.fireRate + gun.reloadTime + 3)
        m["slow_runs"] += 1
        m["slow_dup"] += r.dupAsks
        m["slow_false"] += r.falseAsks
    return m


def checks(m):
    return [
        (m["false"] == 0 and m["wasted"] == 0,
         "I1  asks reaching a server whose magazine held a round: %d (reloads started on a loaded magazine: %d)"
         % (m["false"], m["wasted"])),
        (m["missed"] == 0 and m["dup"] == 0 and m["one_ask"] == 0 and m["reloads"] > 0,
         "I2  empty magazines %d: reloaded %d, still in their first round trip when the run ended %d, missed %d;"
         " asks landing mid-reload %d; runs with >1 ask per empty %d"
         % (m["episodes"], m["reloads"] - m["wasted"], m["episodes"] - (m["reloads"] - m["wasted"]) - m["missed"],
            m["missed"], m["dup"], m["one_ask"])),
        (m["close"] == 0 and m["deaf_bad"] == 0 and m["deaf_asks"] > 0,
         "I3  closest two asks %.3f s apart (window %.1f s); deaf-server runs off one-ask-a-window: %d of %d (%d asks)"
         % (m["min_gap"] if m["min_gap"] < 1e9 else float("nan"), WINDOW, m["deaf_bad"], m["deaf"], m["deaf_asks"])),
        (m["off_asks"] == 0 and m["off"] > 0,
         "I4  AutoReload off: %d asks in %d runs" % (m["off_asks"], m["off"])),
        (m["stuck"] == 0 and m["no_resume"] == 0 and m["resumable"] > 0,
         "I5  all-refused runs where the gun stopped sending past the round-trip age: %d (worst %+.3f s vs the bound);"
         " reloaded runs that never fired again: %d of %d" % (m["stuck"], m["worst_gap_over"], m["no_resume"], m["resumable"])),
    ]


def pins(root):
    rows = []
    for path, text, what in PINS:
        rows.append((text in read(root, path), "pin  %s: %s" % (path.split("/")[-1], what)))
    return rows


# Each plant breaks one invariant in the client's real text, in memory. Aimed at what tryFire must do forever,
# not at the old bug's shape.
PLANTS = [
    ("I1: auto-reload asks on the local round count",
     'if slot.mag <= 0 and Settings.Get("AutoReload")', 'if Settings.Get("AutoReload")'),
    ("I2: a truly empty magazine never asks",
     'if slot.mag <= 0 and Settings.Get("AutoReload")', 'if slot.mag < 0 and Settings.Get("AutoReload")'),
    ("I3: no retry window (asks every dry frame)",
     "now - autoReloadAskedAt > 0.6", "now - autoReloadAskedAt >= 0"),
    ("I3: the window never re-arms (one ask, ever)",
     "autoReloadAskedAt = now\n", "autoReloadAskedAt = now + 1e9\n"),
    ("I4: the AutoReload setting ignored",
     'and Settings.Get("AutoReload") and', "and true and"),
    ("I5: a refused shot never ages out of the local count",
     "if now - shot.t >= rtt + FLIGHT_MARGIN then", "if false then"),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else "."
    src = read(root, CLIENT)
    if "--client-rev" in sys.argv:
        rev = sys.argv[sys.argv.index("--client-rev") + 1]
        src = subprocess.run(["git", "-C", root, "show", rev + ":" + CLIENT], capture_output=True, text=True,
                             check=True).stdout.replace("\r\n", "\n")
        print("auto_reload_check: client from %s" % rev)
    if "--plant" in sys.argv:
        caught = 0
        for name, before, after in PLANTS:
            if before not in src:
                sys.exit("auto_reload_check: plant target missing: " + before)
            rows = checks(run_all(root, src.replace(before, after, 1)))
            hit = any(not ok for ok, _ in rows)
            caught += hit
            print("%s  %s  (%s)" % ("CAUGHT" if hit else "MISSED", name,
                                    "; ".join(line.split("  ")[0] for ok, line in rows if not ok) or "every check passed"))
        print("planted faults caught: %d of %d" % (caught, len(PLANTS)))
        sys.exit(0 if caught == len(PLANTS) else 1)

    m = run_all(root, src)
    print("auto_reload_check: %d guns; %d held-trigger runs (%d round trips x %d ping readings x %d fps x %d refusal rates),"
          " %d deaf-server runs, %d AutoReload-off runs"
          % (m["guns"], m["held"], len(RTTS), len(PING_READS), len(FPS), len(REFUSE), m["deaf"], m["off"]))
    rows = pins(root) + checks(m)
    for ok, line in rows:
        print(("ok    " if ok else "FAIL  ") + line)
    for ex in m["examples"]:
        print("      e.g. " + ex)
    print("info  real round trip 0.8 s (ping clamps to 0.5, past the 0.6 s window), %d runs: %d asks landed mid-reload"
          " and were ignored, %d reached a loaded magazine" % (m["slow_runs"], m["slow_dup"], m["slow_false"]))
    failed = sum(1 for ok, _ in rows if not ok)
    print("auto_reload_check: %d checks, %d failed" % (len(rows), failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
